#requires -version 5.1
<#
  dsh-plugin-bump.ps1  --  move ONE profile plugin to a specific version.

  Why this exists separately from dsh-update.ps1
    dsh-update.ps1 can only install what the declared version range already
    accepts, and pnpm 11 refuses to lock a version published less than
    minimumReleaseAge minutes ago (7 days by default). Plugins that are pinned
    exactly -- dsh-codex-connect, billion-context -- can never move on their
    own, and an actively developed alpha line is always "too new". This script
    is the deliberate, one-package-at-a-time escape hatch.

  What it does
    1. asks tools\dsh-updates.mjs which version the registry currently offers
       for that plugin, and which one is installed
    2. makes a profile snapshot (plugins-<stamp>-pre-bump-<name>)
    3. rewrites that plugin's entry in pnpm-workspace.yaml's
       minimumReleaseAgeExclude list to the new version, so pnpm's release-age
       gate does not refuse the lockfile write (the list already exists for
       exactly this reason)
    4. runs `dsh plugin --profile <p> add <name>@<version> --save-exact`, which
       updates node_modules, the lockfile and the pinned entry in package.json
       in one pass
    5. verifies the result: the installed package.json must report the target
       version and `--dump-config` must still compose the whole plugin tree
    6. on a verification failure it restores the snapshot automatically

  It never starts, stops or restarts DSH -- but a running server keeps the OLD
  plugin code in memory, so restart.bat is needed to actually load the change.

  Exit codes
    0 = done / already at the requested version
    1 = could not resolve, or a fatal error
    2 = -DryRun, nothing was written
    3 = installed, failed verification, rolled back to the snapshot
#>
[CmdletBinding()]
param(
  [string] $Name,
  [string] $Version,
  [string] $Profile = 'web',
  [string] $InstallDir,
  [string] $ProfileDir,
  [switch] $List,
  [switch] $DryRun,
  [switch] $NoSnapshot,
  [switch] $KeepRange
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
if (-not $InstallDir) { $InstallDir = Join-Path $repoRoot 'dsh' }
if (-not $ProfileDir) {
  if ($env:DSH_PROFILE_DIR -and (Split-Path -Leaf $env:DSH_PROFILE_DIR) -eq $Profile) {
    $ProfileDir = $env:DSH_PROFILE_DIR
  } else {
    $homeDir = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    $ProfileDir = Join-Path $homeDir ("profiles\" + $Profile)
  }
}
$ErrorActionPreference = 'Continue'
$bin = Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'

. "$PSScriptRoot\dsh-common.ps1"

function Write-Step([string] $text) { Write-Host (T-Line ("[bump] " + $text)) }
function Write-Warn([string] $text) { Write-Host (T-Line ("[bump] " + $text)) -ForegroundColor Yellow }
function Write-Bad([string] $text) { Write-Host (T-Line ("[bump] " + $text)) -ForegroundColor Red }

function Read-JsonFile([string] $path) {
  $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function Write-TextFile([string] $path, [string] $text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-InstalledPluginVersion([string] $dir, [string] $package) {
  $pj = Join-Path $dir ('node_modules\' + ($package -replace '/', '\') + '\package.json')
  if (-not (Test-Path -LiteralPath $pj)) { return $null }
  try { return (Read-JsonFile $pj).version } catch { return $null }
}

function Test-DshTree([string] $dir, [string] $profile) {
  $b = Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path -LiteralPath $b)) { return [pscustomobject]@{ Ok = $false; Why = 'lib\bin.js is missing' } }
  $cfg = & node $b --profile $profile --dump-config 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    return [pscustomobject]@{ Ok = $false; Why = ("--dump-config exited " + $rc + ": " + ((($cfg | Select-Object -Last 6) -join ' | '))) }
  }
  return [pscustomobject]@{ Ok = $true; Why = 'plugin tree composes cleanly' }
}

# ------------------------------------------------------- the update report
function Get-UpdateReport {
  $script = Join-Path $scriptDir 'dsh-updates.mjs'
  if (-not (Test-Path -LiteralPath $script)) { return $null }
  $raw = & node $script --profile $Profile --dsh $InstallDir --json 2>$null
  if (-not $raw) { return $null }
  try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}

$report = Get-UpdateReport
$deps = (Read-JsonFile (Join-Path $ProfileDir 'package.json')).dependencies
$bundles = @((Read-JsonFile (Join-Path $ProfileDir 'package.json')).dsh.profile.bundles)
$declared = @($deps.PSObject.Properties |
  Where-Object { -not $_.Name.StartsWith('@deepseek-ai/') -and ($bundles -contains $_.Name) } |
  ForEach-Object { $_.Name } | Sort-Object)

$bucket = @{}
foreach ($kind in @('outdated', 'pinned', 'held')) {
  if ($report -and $report.plugins -and $report.plugins.$kind) {
    foreach ($item in @($report.plugins.$kind)) { $bucket[$item.name] = [pscustomobject]@{ kind = $kind; newest = $item.newest; installed = $item.installed } }
  }
}

# ------------------------------------------------------------------- -List
if ($List -or -not $Name) {
  Write-Step ("profile     : " + $Profile + "  (" + $ProfileDir + ")")
  Write-Step ("plugins     : " + $declared.Count + " declared")
  Write-Host ""
  Write-Host ("  {0,-46} {1,-22} {2,-22} {3}" -f 'plugin', 'installed', 'newest', 'status')
  Write-Host ("  " + ('-' * 100))
  foreach ($p in $declared) {
    $inst = Get-InstalledPluginVersion $ProfileDir $p
    $spec = ("" + $deps.$p)
    $b = $bucket[$p]
    $newest = if ($b) { $b.newest } else { $inst }
    $status = if ($b) { $b.kind } elseif ($spec -match '^(file|link|portal|workspace|git)') { 'local/git' } else { 'current' }
    Write-Host ("  {0,-46} {1,-22} {2,-22} {3}" -f $p, ("" + $inst), ("" + $newest), $status)
  }
  Write-Host ""
  Write-Step "bump one with:  bump.bat <plugin>            (bumps to the newest version)"
  Write-Step "                bump.bat <plugin> <version>  (bumps to an exact version)"
  Write-Step "status means: outdated = the declared range accepts the newest version"
  Write-Step "              pinned   = exact version in package.json, nothing moves it by itself"
  Write-Step "              held     = the newest version is too young for pnpm's release-age gate"
  if (-not $report) { Write-Warn "the registry report was unavailable - 'newest' falls back to what is installed" }
  exit 0
}

# ------------------------------------------------------------ resolve target
if ($declared -notcontains $Name) {
  Write-Bad ("'" + $Name + "' is not a community plugin in this profile")
  Write-Bad "run 'bump.bat' with no arguments to see the list"
  exit 1
}

$installedNow = Get-InstalledPluginVersion $ProfileDir $Name
if (-not $Version) {
  $b = $bucket[$Name]
  if (-not $b -or -not $b.newest) {
    Write-Step ($Name + " is already at the newest version the registry offers (" + $installedNow + ")")
    exit 0
  }
  $Version = $b.newest
}
$Version = ("" + $Version).Trim().TrimStart('v', '=')

Write-Step ("plugin      : " + $Name)
Write-Step ("installed   : " + $installedNow)
Write-Step ("target      : " + $Version)

if ($installedNow -eq $Version) {
  Write-Step "already at the requested version - nothing to do"
  exit 0
}

if ($DryRun) {
  Write-Step ("DRYRUN would snapshot the profile, exempt " + $Name + "@" + $Version + " from the release-age gate,")
  Write-Step ("DRYRUN then run: dsh plugin --profile " + $Profile + " add " + $Name + "@" + $Version + " --save-exact")
  exit 2
}

# --------------------------------------------------------------- the snapshot
$snapshotDir = $null
if (-not $NoSnapshot) {
  $snapScript = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
  if (Test-Path -LiteralPath $snapScript) {
    Write-Step "snapshotting the profile first"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $snapScript -Mode snapshot -Name ("pre-bump-" + ($Name -replace '[^A-Za-z0-9._-]', '-')) -Profile $Profile 2>&1
    foreach ($line in $out) {
      $m = [regex]::Match(("" + $line), 'snapshot created:\s*(.+?)\s+kind=')
      if ($m.Success) { $snapshotDir = $m.Groups[1].Value.Trim() }
    }
    if ($snapshotDir) { Write-Step ("snapshot    : " + (Split-Path -Leaf $snapshotDir)) }
    else { Write-Warn "the snapshot path could not be read from its output" }
  } else {
    Write-Warn "dsh-plugin-backup.ps1 was not found - continuing without a snapshot"
  }
}

function Restore-Snapshot {
  if (-not $snapshotDir) { Write-Bad "there is no snapshot to roll back to"; return $false }
  $snapScript = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
  Write-Warn ("restoring " + (Split-Path -Leaf $snapshotDir))
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $snapScript -Mode restore -Name (Split-Path -Leaf $snapshotDir) -Yes -Profile $Profile 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Bad "the restore reported a failure"; return $false }
  return $true
}

# ------------------------------------------- release-age exemption for the new
# pnpm 11 will not write a lockfile entry for a version younger than
# minimumReleaseAge (7 days by default), and an exact pin cannot fall back to
# an older version -- so without this the install would simply refuse to happen.
function Set-ReleaseAgeExclude([string] $workspaceFile, [string] $package, [string] $target) {
  $entry = $package + '@' + $target
  # YAML reserves a leading '@'. A scoped package name written bare makes pnpm
  # reject the WHOLE workspace file ("bad indentation of a sequence entry"), so
  # scoped entries have to be single-quoted.
  if ($entry.StartsWith('@')) { $entry = "'" + $entry + "'" }
  if (-not (Test-Path -LiteralPath $workspaceFile)) {
    Write-Warn "pnpm-workspace.yaml was not found - the release-age gate may refuse the install"
    return $false
  }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($l in [System.IO.File]::ReadAllLines($workspaceFile, [System.Text.Encoding]::UTF8)) { $lines.Add($l) }

  $headerIdx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*minimumReleaseAgeExclude\s*:') { $headerIdx = $i; break }
  }
  if ($headerIdx -lt 0) {
    $lines.Add('')
    $lines.Add('minimumReleaseAgeExclude:')
    $lines.Add('  - ' + $entry)
    Write-TextFile $workspaceFile (($lines -join "`r`n") + "`r`n")
    Write-Step ("release-age exemption added: " + $entry)
    return $true
  }

  # Replace a same-package entry in place so the list cannot grow forever.
  $lastItem = $headerIdx
  $replaced = $false
  for ($i = $headerIdx + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '^\s*-\s+') { break }
    $lastItem = $i
    $value = ($lines[$i] -replace '^\s*-\s+', '').Trim().Trim("'").Trim('"')
    if ($value -eq $package -or $value -like ($package + '@*')) {
      $indent = ([regex]::Match($lines[$i], '^\s*-\s+')).Value
      $lines[$i] = $indent + $entry
      $replaced = $true
      break
    }
  }
  if (-not $replaced) {
    $indent = ([regex]::Match($lines[$lastItem], '^(\s*-\s+)')).Groups[1].Value
    if (-not $indent) { $indent = '  - ' }
    $lines.Insert($lastItem + 1, $indent + $entry)
  }
  Write-TextFile $workspaceFile (($lines -join "`r`n") + "`r`n")
  if ($replaced) { Write-Step ("release-age exemption moved to: " + $entry) }
  else { Write-Step ("release-age exemption added: " + $entry) }
  return $true
}

$workspaceFile = Join-Path $ProfileDir 'pnpm-workspace.yaml'
if ($KeepRange) {
  Write-Warn "-KeepRange given - the release-age exemption is still needed, the exact pin is not"
}
$null = Set-ReleaseAgeExclude $workspaceFile $Name $Version

# ------------------------------------------------------------------- install
$pre = Test-DshTree $InstallDir $Profile
if (-not $pre.Ok) { Write-Warn ("the plugin tree is already broken before this change: " + $pre.Why) }

Write-Step ("installing " + $Name + "@" + $Version + " (this can take a minute)")
$addArgs = @($bin, 'plugin', '--profile', $Profile, 'add', ($Name + '@' + $Version))
if (-not $KeepRange) { $addArgs += '--save-exact' }
& node @addArgs 2>&1 | Select-Object -Last 25 | ForEach-Object { Write-Host ("       " + $_) }
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Warn ("pnpm reported exit code " + $rc + " - checking the result anyway") }

# ---------------------------------------------------------------- verify
$after = Get-InstalledPluginVersion $ProfileDir $Name
Write-Step ("installed   : " + $after)
$ok = ($after -eq $Version)
if (-not $ok) { Write-Bad ("node_modules still holds " + $after + " instead of " + $Version) }
$tree = Test-DshTree $InstallDir $Profile
if ($tree.Ok) { Write-Step ("verified    : " + $tree.Why) } else { Write-Bad ("verification failed: " + $tree.Why) }

if ($ok -and $tree.Ok) {
  Write-Host ""
  Write-Step ("done: " + $Name + " is now " + $Version)
  Write-Step "a running DSH keeps the old plugin code in memory - run restart.bat to load it"
  exit 0
}

if (-not $pre.Ok -and $tree.Ok) {
  Write-Warn "the tree was already broken before this change; nothing to roll back"
  exit 1
}
if (-not $pre.Ok) {
  Write-Bad "the tree was broken before and after - restoring the snapshot would not help"
  exit 1
}
if (Restore-Snapshot) { exit 3 }
exit 1
