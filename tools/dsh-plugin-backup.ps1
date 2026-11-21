<#
  dsh-plugin-backup.ps1 - snapshot / restore the dsh profile plugin set.

  Snapshot contents (one folder per snapshot):
    profile\   package.json, cordis.patch.yml, cordis.yml,
               pnpm-workspace.yaml, pnpm-lock.yaml   (whatever exists)
    packages\  the installed plugin package directories, copied whole
    manifest.json, plugins.txt

  Modes:
    snapshot (default)  take a manual snapshot now
    auto                snapshot only when the plugin set changed; used by run.bat
                        and by the DSH-Plugin-AutoBackup scheduled task
    list                list snapshots
    restore             restore a snapshot (-Name to preselect, otherwise ask)
    task-on / task-off  create / remove the periodic auto-backup task

  This script never starts or stops dsh. After a restore you restart it yourself.

  Exit codes: 0 ok, 1 error, 2 nothing to do.
#>
[CmdletBinding()]
param(
  [ValidateSet('snapshot', 'auto', 'list', 'restore', 'task-on', 'task-off')]
  [string]$Mode = 'snapshot',
  [string]$Name = '',
  [int]$Keep = 10,
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$SkipPnpm,
  [string]$Profile = 'web',
  [string]$ProfileDir = '',
  [string]$BackupRoot = '',
  [string]$DshHome = '',
  [int]$IntervalMinutes = 15
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

. "$PSScriptRoot\dsh-common.ps1"

# No folder-position assumption: backups live next to this tools\ folder.
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'backups' }

function Write-Log([string]$message) {
  $line = "[$(Get-Date -Format o)] $(T-Line $message)"
  Write-Host $line
  try {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    [System.IO.File]::AppendAllText((Join-Path $BackupRoot 'backup.log'), $line + "`r`n", $script:Utf8NoBom)
  } catch { }
}

function Read-JsonFile($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
}

function Get-PackageVersion([string]$packageDir) {
  $manifest = Read-JsonFile (Join-Path $packageDir 'package.json')
  if ($manifest -ne $null -and $manifest.version) { return [string]$manifest.version }
  return ''
}

function Get-FileHashSafe([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
  try { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } catch { return 'unreadable' }
}

function Resolve-Home {
  if ($DshHome -ne '') { return $DshHome }
  if ($env:DSH_HOME -and $env:DSH_HOME.Trim() -ne '') { return $env:DSH_HOME }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Get-ProfilePath {
  if ($ProfileDir -ne '') { return (Resolve-Path -LiteralPath $ProfileDir).Path }
  return (Join-Path (Join-Path (Resolve-Home) 'profiles') $Profile)
}

function Get-ProfileState([string]$dir) {
  $manifest = Read-JsonFile (Join-Path $dir 'package.json')
  $deps = @()
  $bundles = @()
  if ($manifest -ne $null) {
    if ($manifest.dependencies) { $deps = @($manifest.dependencies.PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($manifest.dsh -and $manifest.dsh.profile -and $manifest.dsh.profile.bundles) { $bundles = @($manifest.dsh.profile.bundles) }
  }
  $nodes = Join-Path $dir 'node_modules'
  $items = @()
  foreach ($name in ($deps | Sort-Object)) {
    $pkgDir = Join-Path $nodes $name
    $version = ''
    $present = Test-Path -LiteralPath $pkgDir
    if ($present) { $version = Get-PackageVersion $pkgDir }
    $isBundle = $false
    if ($bundles -contains $name) { $isBundle = $true }
    $items += [pscustomobject]@{ name = $name; version = $version; present = $present; bundle = $isBundle; dir = $pkgDir }
  }
  return [pscustomobject]@{
    dir      = $dir
    deps     = $deps
    bundles  = $bundles
    items    = $items
    manifest = $manifest
  }
}

function Get-Fingerprint($state) {
  $parts = @()
  $parts += 'profile=' + $Profile
  foreach ($item in $state.items) { $parts += ($item.name + '@' + $item.version + '|bundle=' + $item.bundle) }
  $parts += 'bundles=' + ($state.bundles -join ',')
  $parts += 'pkg=' + (Get-FileHashSafe (Join-Path $state.dir 'package.json'))
  $parts += 'patch=' + (Get-FileHashSafe (Join-Path $state.dir 'cordis.patch.yml'))
  $parts += 'lock=' + (Get-FileHashSafe (Join-Path $state.dir 'pnpm-lock.yaml'))
  $joined = $parts -join "`n"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))).Replace('-', '').ToLower() }
  finally { $sha.Dispose() }
}

function Get-DshVersion {
  $mirror = Join-Path (Join-Path (Resolve-Home) 'profiles') 'node_modules\@deepseek-ai\dsh'
  return (Get-PackageVersion $mirror)
}

function Get-SnapshotDirs {
  if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
  return @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'plugins-*' } | Sort-Object Name -Descending)
}

function Get-SnapshotKind([string]$snapDir) {
  $manifest = Read-JsonFile (Join-Path $snapDir 'manifest.json')
  if ($manifest -ne $null -and $manifest.kind) { return [string]$manifest.kind }
  return 'unknown'
}

function Get-LastAutoFingerprint {
  foreach ($snap in (Get-SnapshotDirs)) {
    $manifest = Read-JsonFile (Join-Path $snap.FullName 'manifest.json')
    if ($manifest -ne $null -and $manifest.kind -eq 'auto' -and $manifest.fingerprint) { return [string]$manifest.fingerprint }
  }
  return ''
}

function Test-PnpmBusy {
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' or Name='pnpm.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in $procs) {
      if ($proc.CommandLine -and $proc.CommandLine -match 'pnpm') { return $true }
    }
  } catch { }
  return $false
}

function Copy-PluginPackages($state, [string]$snapshotDir) {
  $targetRoot = Join-Path $snapshotDir 'packages'
  $copied = @()
  $bytes = 0
  foreach ($item in $state.items) {
    if (-not $item.present) { continue }
    if (-not (Test-Path -LiteralPath $item.dir)) { continue }
    $target = Join-Path $targetRoot $item.name
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $item.dir -Destination $target -Recurse -Force
    $size = 0
    try { $size = (Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
    if ($size -eq $null) { $size = 0 }
    $bytes += $size
    $copied += ($item.name + '@' + $item.version)
  }
  return [pscustomobject]@{ copied = $copied; bytes = $bytes }
}

function New-Snapshot([string]$kind) {
  $state = Get-ProfileState (Get-ProfilePath)
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $suffix = ''
  if ($kind -eq 'prerestore') { $suffix = '-prerestore' }
  if ($kind -eq 'manual') { $suffix = '-manual' }
  # An explicit -Name tags the snapshot so it can be found again by name. The
  # update helper needs that: it has to be able to roll back to exactly the
  # snapshot it took seconds earlier, not to "whichever snapshot is newest now".
  # Until this was honoured, "-Name pre-dsh-update" was silently discarded and
  # every update snapshot came out as an anonymous "-manual" one.
  $tag = ''
  if ($Name -and $Name.Trim() -ne '') {
    $tag = ($Name.Trim() -replace '[^A-Za-z0-9._-]', '-')
    $suffix = '-' + $tag
  }
  $snapshotDir = Join-Path $BackupRoot ('plugins-' + $stamp + $suffix)
  New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
  $profileOut = Join-Path $snapshotDir 'profile'
  New-Item -ItemType Directory -Force -Path $profileOut | Out-Null

  $configFiles = @('package.json', 'cordis.patch.yml', 'cordis.yml', 'pnpm-workspace.yaml', 'pnpm-lock.yaml')
  $saved = @()
  foreach ($file in $configFiles) {
    $source = Join-Path $state.dir $file
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $profileOut $file) -Force
      $saved += $file
    }
  }

  $packages = Copy-PluginPackages $state $snapshotDir
  $fingerprint = Get-Fingerprint $state

  $manifest = [pscustomobject]@{
    format      = 'dsh-plugin-backup/1'
    kind        = $kind
    at          = (Get-Date -Format o)
    profile     = $Profile
    profileDir  = $state.dir
    dshVersion  = (Get-DshVersion)
    bundles     = $state.bundles
    plugins     = @($state.items | ForEach-Object { [pscustomobject]@{ name = $_.name; version = $_.version; bundle = $_.bundle } })
    fingerprint = $fingerprint
    configFiles = $saved
    packageBytes = $packages.bytes
    copied      = $packages.copied
    machine     = $env:COMPUTERNAME
    user        = $env:USERNAME
  }
  $json = $manifest | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText((Join-Path $snapshotDir 'manifest.json'), $json, $script:Utf8NoBom)

  $lines = @()
  $lines += '# dsh plugin backup ' + $manifest.at
  $lines += '# profile: ' + $state.dir
  $lines += '# dsh version: ' + $manifest.dshVersion
  $lines += ''
  foreach ($item in $state.items) {
    $mark = 'dep'
    if ($item.bundle) { $mark = 'bundle' }
    if (-not $item.present) { $mark = $mark + ', MISSING on disk' }
    $lines += ($item.name + '  ' + $item.version + '  [' + $mark + ']')
  }
  [System.IO.File]::WriteAllText((Join-Path $snapshotDir 'plugins.txt'), ($lines -join "`r`n") + "`r`n", $script:Utf8NoBom)

  $mb = [math]::Round($packages.bytes / 1MB, 2)
  Write-Log ("snapshot created: " + $snapshotDir + "  kind=" + $kind + "  plugins=" + $packages.copied.Count + "  packages=" + $mb + " MB")
  if ($tag -ne '') {
    # Only the auto snapshots used to be rotated, so every named snapshot was
    # kept forever. At several hundred MB apiece that is an unbounded leak; keep
    # the newest few of each tag and let the rest go.
    Remove-OldNamedSnapshots $tag 3
  }
  return $snapshotDir
}

function Remove-OldNamedSnapshots([string]$tag, [int]$keep) {
  if (-not $tag) { return }
  $named = @(Get-SnapshotDirs | Where-Object { $_.Name -match ('-' + [regex]::Escape($tag) + '($|-)') })
  if ($named.Count -le $keep) { return }
  foreach ($old in ($named | Select-Object -Skip $keep)) {
    try {
      Remove-Item -LiteralPath $old.FullName -Recurse -Force
      Write-Log ("rotated old '" + $tag + "' snapshot: " + $old.Name)
    } catch { Write-Log ("could not rotate " + $old.Name + ": " + $_.Exception.Message) }
  }
}

function Remove-OldAutoSnapshots {
  $autos = @(Get-SnapshotDirs | Where-Object { (Get-SnapshotKind $_.FullName) -eq 'auto' })
  if ($autos.Count -le $Keep) { return }
  foreach ($old in ($autos | Select-Object -Skip $Keep)) {
    try {
      Remove-Item -LiteralPath $old.FullName -Recurse -Force
      Write-Log ("rotated old auto snapshot: " + $old.Name)
    } catch { Write-Log ("could not rotate " + $old.Name + ": " + $_.Exception.Message) }
  }
}

function Show-Snapshots {
  $snaps = Get-SnapshotDirs
  if ($snaps.Count -eq 0) { Write-Host 'no snapshots yet'; return @() }
  $index = 0
  $rows = @()
  foreach ($snap in $snaps) {
    $index = $index + 1
    $manifest = Read-JsonFile (Join-Path $snap.FullName 'manifest.json')
    $kind = 'unknown'
    $count = 0
    $when = $snap.Name
    if ($manifest -ne $null) {
      if ($manifest.kind) { $kind = [string]$manifest.kind }
      if ($manifest.plugins) { $count = @($manifest.plugins).Count }
      if ($manifest.at) { $when = [string]$manifest.at }
    }
    $rows += [pscustomobject]@{ index = $index; name = $snap.Name; kind = $kind; plugins = $count; at = $when }
  }
  Write-Host ($rows | Format-Table -AutoSize | Out-String -Width 200)
  return $snaps
}

function Resolve-Snapshot([string]$wanted) {
  $snaps = Get-SnapshotDirs
  if ($snaps.Count -eq 0) { throw 'no snapshots to restore' }
  if ($wanted -ne '') {
    if ($wanted -match '^\d+$') {
      $idx = [int]$wanted
      if ($idx -ge 1 -and $idx -le $snaps.Count) { return $snaps[$idx - 1].FullName }
      throw ('snapshot number out of range: ' + $wanted)
    }
    $match = @($snaps | Where-Object { $_.Name -like ('*' + $wanted + '*') })
    if ($match.Count -eq 1) { return $match[0].FullName }
    if ($match.Count -eq 0) { throw ('no snapshot matches: ' + $wanted) }
    throw ('more than one snapshot matches: ' + $wanted)
  }
  if ($DryRun -or $Yes -or [Console]::IsInputRedirected) { return $snaps[0].FullName }
  $null = Show-Snapshots
  $answer = Read-Host 'restore which snapshot? [1 = newest, Enter = newest, q = cancel]'
  if ($answer -eq 'q') { return '' }
  if ([string]::IsNullOrWhiteSpace($answer)) { return $snaps[0].FullName }
  if ($answer -match '^\d+$') {
    $idx = [int]$answer
    if ($idx -ge 1 -and $idx -le $snaps.Count) { return $snaps[$idx - 1].FullName }
    throw ('snapshot number out of range: ' + $answer)
  }
  throw ('not a snapshot number: ' + $answer)
}

function Invoke-Restore([string]$snapshotDir) {
  $state = Get-ProfileState (Get-ProfilePath)
  $snapshotManifest = Read-JsonFile (Join-Path $snapshotDir 'manifest.json')
  if ($snapshotManifest -eq $null) { throw ('snapshot has no manifest.json: ' + $snapshotDir) }

  $snapshotPlugins = @()
  if ($snapshotManifest.plugins) { $snapshotPlugins = @($snapshotManifest.plugins | ForEach-Object { [string]$_.name }) }
  $currentPlugins = @($state.items | ForEach-Object { [string]$_.name })
  $toRemove = @($currentPlugins | Where-Object { $snapshotPlugins -notcontains $_ })

  $profileFiles = @()
  $profileSource = Join-Path $snapshotDir 'profile'
  if (Test-Path -LiteralPath $profileSource) {
    $profileFiles = @(Get-ChildItem -LiteralPath $profileSource -File | ForEach-Object { $_.Name })
  }

  $packageDirs = @()
  $packagesSource = Join-Path $snapshotDir 'packages'
  if (Test-Path -LiteralPath $packagesSource) {
    $packageDirs = @(Get-ChildItem -LiteralPath $packagesSource -Directory -Recurse -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') } |
      ForEach-Object { $_.FullName.Substring($packagesSource.Length + 1) })
  }

  Write-Host ''
  Write-Host ('snapshot : ' + (Split-Path -Leaf $snapshotDir))
  Write-Host ('profile  : ' + $state.dir)
  Write-Host ('restore  : ' + ($profileFiles -join ', '))
  Write-Host ('packages : ' + $packageDirs.Count)
  if ($toRemove.Count -gt 0) { Write-Host ('remove   : ' + ($toRemove -join ', ')) }
  Write-Host ''

  if ($DryRun) {
    Write-Host 'dry run: nothing was written.'
    return
  }

  Write-Host 'taking a safety snapshot of the current state first ...'
  $null = New-Snapshot 'prerestore'

  foreach ($file in $profileFiles) {
    $source = Join-Path $profileSource $file
    $target = Join-Path $state.dir $file
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Host ('restored ' + $file)
  }

  foreach ($rel in $packageDirs) {
    $source = Join-Path $packagesSource $rel
    $target = Join-Path (Join-Path $state.dir 'node_modules') $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    Write-Host ('restored package ' + $rel)
  }

  foreach ($name in $toRemove) {
    $target = Join-Path (Join-Path $state.dir 'node_modules') $name
    if (Test-Path -LiteralPath $target) {
      Remove-Item -LiteralPath $target -Recurse -Force
      Write-Host ('removed package ' + $name)
    }
  }

  if (-not $SkipPnpm) {
    $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($pnpm -eq $null) {
      Write-Host 'pnpm not found on PATH; dependency repair skipped (packages were copied back).'
    } else {
      Write-Host 'repairing dependencies with pnpm (best effort) ...'
      $ok = $false
      Push-Location -LiteralPath $state.dir
      try {
        foreach ($args in @(@('install', '--frozen-lockfile', '--offline'), @('install', '--frozen-lockfile'), @('install', '--no-frozen-lockfile'))) {
          try {
            & cmd /c ('pnpm ' + ($args -join ' ') + ' 2>&1') | ForEach-Object { Write-Host ('  ' + $_) }
            if ($LASTEXITCODE -eq 0) { $ok = $true; break }
          } catch {
            Write-Host ('  pnpm attempt failed: ' + $_.Exception.Message)
          }
        }
      } finally { Pop-Location }
      if ($ok) { Write-Host 'dependency repair finished.' } else { Write-Host 'dependency repair failed; packages were still copied back.' }
    }
  }

  Write-Log ('restored snapshot ' + (Split-Path -Leaf $snapshotDir) + ' into ' + $state.dir)
  Write-Host ''
  Write-Host 'restore done. This script never restarts dsh:'
  Write-Host '  close the dsh web console window, then double-click run.bat.'
}

function Get-TaskCommand {
  $script = Join-Path $PSScriptRoot 'dsh-plugin-backup.ps1'
  $launcher = Join-Path $PSScriptRoot 'run-hidden.vbs'
  if (Test-Path -LiteralPath $launcher) {
    # Go through wscript.exe + window style 0 (see run-hidden.vbs). Running
    # powershell.exe straight from Task Scheduler creates a console, and on
    # Windows 11 with Windows Terminal as the default terminal that console is
    # handed off to a brand new Terminal window - which flashes on the desktop
    # for the second this no-op backup takes. wscript.exe never creates one.
    return 'wscript.exe ' + $launcher + ' dsh-plugin-backup.ps1 -Mode auto'
  }
  return 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -Mode auto'
}

function Enable-Task {
  $name = 'DSH-Plugin-AutoBackup'
  $command = Get-TaskCommand
  $out = & cmd /c ('schtasks /create /tn "' + $name + '" /tr "' + $command + '" /sc minute /mo ' + $IntervalMinutes + ' /f 2>&1')
  $out | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -eq 0) { Write-Log ('scheduled task created: ' + $name + ' every ' + $IntervalMinutes + ' min') } else { Write-Log 'scheduled task creation failed' }
}

function Disable-Task {
  $name = 'DSH-Plugin-AutoBackup'
  $out = & cmd /c ('schtasks /delete /tn "' + $name + '" /f 2>&1')
  $out | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -eq 0) { Write-Log ('scheduled task removed: ' + $name) }
}

# ---------------------------------------------------------------- dispatch ---
try {
  if (-not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }

  switch ($Mode) {
    'snapshot' {
      $null = New-Snapshot 'manual'
      exit 0
    }
    'auto' {
      if (Test-PnpmBusy) { Write-Log 'auto backup skipped: a pnpm process is running'; exit 2 }
      $state = Get-ProfileState (Get-ProfilePath)
      $fingerprint = Get-Fingerprint $state
      if ($fingerprint -eq (Get-LastAutoFingerprint)) { exit 2 }
      $null = New-Snapshot 'auto'
      Remove-OldAutoSnapshots
      exit 0
    }
    'list' {
      $null = Show-Snapshots
      exit 0
    }
    'restore' {
      $snapshotDir = Resolve-Snapshot $Name
      if ($snapshotDir -eq '') { Write-Host 'cancelled'; exit 2 }
      if (-not $Yes -and -not $DryRun) {
        $answer = Read-Host ('type YES to restore ' + (Split-Path -Leaf $snapshotDir))
        if ($answer -ne 'YES') { Write-Host 'cancelled'; exit 2 }
      }
      Invoke-Restore $snapshotDir
      exit 0
    }
    'task-on' { Enable-Task; exit 0 }
    'task-off' { Disable-Task; exit 0 }
  }
} catch {
  Write-Host ('ERROR: ' + $_.Exception.Message)
  Write-Log ('ERROR: ' + $_.Exception.Message)
  exit 1
}
