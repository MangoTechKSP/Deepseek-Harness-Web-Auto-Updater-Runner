#requires -version 5.1
<#
  dsh-update.ps1  --  in-place DSH update helper, called by run.bat

  What it does
    1. asks npm which version the configured dist-tag points at
    2. compares that with the local install in -InstallDir
    3. if they differ, copies the whole install to backups\dsh-install\previous
       FIRST, then installs the new version INTO THE SAME FOLDER
       (npm rewrites .\dsh\node_modules\@deepseek-ai\dsh - no parallel
        npx copies pile up any more)
    4. verifies the result before trusting it:
         node <bin> --version                      -> must report the new version
         node <bin> --profile <p> --dump-config    -> must compose the whole
                                                      plugin tree and exit 0
       This is the step that turns "npm said ok" into "DSH actually works".
       A failure here restores backups\dsh-install\previous automatically.
    5. asks tools\dsh-updates.mjs whether any profile plugin is behind, and
       updates the plugins when DSH changed, when -ForcePluginUpdate was given,
       or when a plugin actually has an update the declared range accepts
    6. snapshots the plugin profile before touching it and verifies again after;
       a failure restores that snapshot automatically
    7. approves any dependency build script npm 11 has not seen yet and reruns
       the builds, so a native dependency is never silently skipped
    8. removes leftover npx copies of @deepseek-ai/dsh (only after the local
       install is verified, i.e. never leaves you without a DSH)
    9. remembers a version that failed to install or verify in
       backups\dsh-install\failed-versions.json and does NOT retry it on the
       next start-up (default: 12 hours). Without this, a tag that points at a
       broken or half-published release makes every single boot pay for a full
       install backup, a failing npm install and a rollback.

  It NEVER starts, stops or restarts DSH. That is up to the user.

  Useful switches
    -DryRun         : report what would happen, write nothing (exit 2)
    -Rollback       : restore backups\dsh-install\previous over the install
    -Rollback -DryRun: show that a rollback is possible, change nothing
    -BackupOnly     : refresh backups\dsh-install\previous from the CURRENT
                      install without installing anything
    -CheckOnly      : answer "is there anything to update?" and write NOTHING.
                      Installs nothing, snapshots nothing. exit 10 = yes,
                      0 = everything is already up to date. The logon path
                      uses this to decide whether to show the update popup.
    -Tag <t>        : npm dist-tag to track (default latest; 'next' is the
                      bleeding edge - see run.bat's header for why latest)
    -IgnoreUpdateFailures       : ignore the retry-after list and try again NOW
    -RetryFailedAfterHours <n>  : how long a failed version stays suppressed
                                  (0 disables the memory entirely)
    -SkipPluginUpdate / -SkipNpxCleanup / -SkipInstallBackup

  Exit codes
    0 = up to date / updated fine / rollback verified / backup refreshed
    1 = could not resolve a version or the install failed fatally
    2 = running with -DryRun, nothing was written
    3 = the new version was installed, failed verification and was rolled back
   10 = -CheckOnly only: an update is available
#>
[CmdletBinding()]
param(
  [string] $Tag = 'latest',
  [string] $Profile = 'web',
  [string] $InstallDir,
  [int]    $Port = 3080,
  [switch] $ForcePluginUpdate,
  [switch] $SkipPluginUpdate,
  [switch] $SkipNpxCleanup,
  [switch] $SkipInstallBackup,
  [switch] $DryRun,
  [switch] $Rollback,
  [switch] $BackupOnly,
  [switch] $CheckOnly,
  [int]    $RetryFailedAfterHours = 12,
  [switch] $IgnoreUpdateFailures,
  [switch] $IgnorePluginCompat
)

# $PSScriptRoot is not reliable inside a param() default, so resolve it here.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $InstallDir) { $InstallDir = Join-Path $scriptDir '..\dsh' }

$ErrorActionPreference = 'Continue'
$script:RepoRoot = Split-Path -Parent $scriptDir

. "$PSScriptRoot\dsh-common.ps1"

function Write-Step([string] $text) { Write-Host (T-Line ("[dsh] " + $text)) }
function Write-Warn([string] $text) { Write-Host (T-Line ("[dsh] " + $text)) -ForegroundColor Yellow }
function Write-Bad([string] $text) { Write-Host (T-Line ("[dsh] " + $text)) -ForegroundColor Red }

function Get-NpmCmd {
  $c = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $nodeDir = Join-Path (Split-Path (Get-Command node -ErrorAction SilentlyContinue).Source) 'npm.cmd'
  if (Test-Path $nodeDir) { return $nodeDir }
  return 'npm.cmd'
}

function Get-InstalledDshVersion([string] $dir) {
  $pj = Join-Path $dir 'node_modules\@deepseek-ai\dsh\package.json'
  if (-not (Test-Path $pj)) { return $null }
  try {
    $text = [System.IO.File]::ReadAllText($pj, [System.Text.Encoding]::UTF8)
    return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json).version
  } catch { return $null }
}

function Test-DshServerListening([int] $port) {
  $hit = netstat -ano | Select-String -SimpleMatch (":" + $port + " ") | Select-String -SimpleMatch 'LISTENING'
  return [bool]$hit
}

# ------------------------------------------------------------- install backup
function Get-InstallBackupRoot { return (Join-Path $script:RepoRoot 'backups\dsh-install') }

function Invoke-Robocopy([string] $Source, [string] $Destination, [string] $What) {
  if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  }
  $null = & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 /MT:16
  $rc = $LASTEXITCODE
  # robocopy reports bit flags, not a conventional exit code: 0-7 all mean
  # "worked" (1 = files copied, 2 = extras removed, ...), 8 and up mean trouble.
  if ($rc -ge 8) { Write-Warn ($What + " failed (robocopy exit " + $rc + ")"); return $false }
  return $true
}

function Get-InstallBackupInfo {
  $meta = Join-Path (Get-InstallBackupRoot) 'previous.json'
  if (-not (Test-Path -LiteralPath $meta)) { return $null }
  try { return ([System.IO.File]::ReadAllText($meta, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return $null }
}

function Backup-DshInstall([string] $Reason) {
  $root = Get-InstallBackupRoot
  $previous = Join-Path $root 'previous'
  $staging = Join-Path $root 'staging'
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }

  $version = Get-InstalledDshVersion $InstallDir
  $sizeGb = 0
  try {
    $sizeGb = [math]::Round((Get-ChildItem -LiteralPath $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue |
      Measure-Object Length -Sum).Sum / 1GB, 2)
  } catch { }
  $free = [math]::Round((Get-PSDrive (Split-Path -Qualifier $InstallDir).TrimEnd(':')).Free / 1GB, 2)
  Write-Step ("install backup: " + $sizeGb + " GB to copy, " + $free + " GB free")
  if ($free -gt 0 -and $sizeGb -gt 0 -and $free -lt ($sizeGb + 1)) {
    Write-Warn "not enough free space for a safe rollback copy"
    return $null
  }

  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
  if (-not (Invoke-Robocopy $InstallDir $staging 'install backup')) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    return $null
  }
  # Only replace the previous rollback point once the new copy is complete, so a
  # crash or a full disk mid-copy cannot leave the machine with no way back.
  if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $staging -Destination $previous -Force

  $info = [pscustomobject]@{
    version   = $version
    createdAt = (Get-Date -Format o)
    reason    = $Reason
    sizeGb    = $sizeGb
  }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $root 'previous.json'), ($info | ConvertTo-Json -Depth 4), $enc)
  Write-Step ("install backup ready: " + $previous + "  (was " + $version + ")")
  return $previous
}

function Get-FailedVersions {
  $meta = Join-Path (Get-InstallBackupRoot) 'failed-versions.json'
  if (-not (Test-Path -LiteralPath $meta)) { return @{} }
  try {
    $obj = ([System.IO.File]::ReadAllText($meta, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
  } catch { return @{} }
  $map = @{}
  if ($obj) { foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value } }
  return $map
}

# A version that installed but did not verify must not be retried on every
# single boot: each attempt costs a full 0.44 GB install backup, a failing npm
# install and a rollback, and turns a silent start into a slow, noisy one.
function Test-VersionSuppressed([string] $version) {
  if ($IgnoreUpdateFailures) { return $false }
  $map = Get-FailedVersions
  if (-not $map.ContainsKey($version)) { return $false }
  $until = [datetime]::MinValue
  if (-not [datetime]::TryParse([string]$map[$version], [ref]$until)) { return $false }
  if ((Get-Date) -lt $until) { $script:suppressUntil = $until; return $true }
  return $false
}

function Add-FailedVersion([string] $version) {
  if ($RetryFailedAfterHours -le 0) { return }
  $map = Get-FailedVersions
  $until = (Get-Date).AddHours($RetryFailedAfterHours)
  $map[$version] = $until.ToString('o')
  $root = Get-InstallBackupRoot
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $root 'failed-versions.json'), ($map | ConvertTo-Json -Depth 4), $enc)
  Write-Step ("this version will not be retried before " + $until.ToString('yyyy-MM-dd HH:mm'))
}

function Restore-DshInstall {  $previous = Join-Path (Get-InstallBackupRoot) 'previous'
  if (-not (Test-Path -LiteralPath $previous)) {
    Write-Bad "there is no install backup to roll back to"
    return $false
  }
  $info = Get-InstallBackupInfo
  $label = if ($info -and $info.version) { [string]$info.version } else { 'the previous version' }
  Write-Warn ("rolling the DSH install back to " + $label)
  if (-not (Invoke-Robocopy $previous $InstallDir 'rollback')) {
    Write-Bad "the rollback copy itself failed - backups\dsh-install\previous is still intact"
    return $false
  }
  Write-Step ("rolled back; installed version is now " + (Get-InstalledDshVersion $InstallDir))
  return $true
}

# -------------------------------------------------------------- verification
<#
  The check that matters. A DSH install is only "good" if the executable runs
  AND the whole plugin tree still composes -- a plugin whose cordis patch no
  longer applies takes the server down just as thoroughly as a missing binary.
  `--dump-config` composes that tree without binding a port, so it is safe to
  run while another DSH is already serving.
#>
function Test-DshTree([string] $dir, [string] $profile, [string] $expectVersion) {
  $bin = Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path -LiteralPath $bin)) {
    return [pscustomobject]@{ Ok = $false; Why = 'lib\bin.js is missing' }
  }
  # Capture the WHOLE output first, then pick a line. Piping straight into
  # Select-Object -First 1 tears the pipeline down while node is still running,
  # which leaves $LASTEXITCODE = -1 on a perfectly healthy install (measured:
  # 39 of 40 runs on a known-good tree). That false negative made a good update
  # look broken and rolled it back, so never shorten the pipeline here.
  $vout = & node $bin --version 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    $tail = ((@($vout) | Select-Object -Last 4) -join ' | ')
    return [pscustomobject]@{ Ok = $false; Why = ("--version exited " + $rc + ": " + $tail) }
  }
  $v = ("" + (@($vout) | Select-Object -First 1)).Trim()
  if ($expectVersion -and $v -ne $expectVersion) {
    return [pscustomobject]@{ Ok = $false; Why = ("--version reports " + $v + " instead of " + $expectVersion) }
  }
  $cfg = & node $bin --profile $profile --dump-config 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    $tail = (($cfg | Select-Object -Last 6) -join ' | ')
    return [pscustomobject]@{ Ok = $false; Why = ("--dump-config exited " + $rc + ": " + $tail) }
  }
  return [pscustomobject]@{ Ok = $true; Why = $v }
}

# ------------------------------- would a NEW dsh still load these plugins?
# DSH drops any plugin whose @deepseek-ai/dsh-* peers do not accept the runtime
# it is running, and it only mentions that in its start-up console output. A real
# dsh 0.2.0-rc.2 was measured to skip 7 of the 12 plugins installed here, so ask
# the question BEFORE installing: an upgrade that quietly strips the plugin set is
# not an upgrade anyone wants.
function Get-PluginCompatBlock([string] $version) {
  $script = Join-Path $scriptDir 'dsh-plugin-health.mjs'
  if (-not (Test-Path -LiteralPath $script)) { return $null }
  $raw = & node $script --profile $Profile --dsh $InstallDir --against $version --json 2>$null
  if (-not $raw) { return $null }
  try {
    $j = (($raw -join "`n") | ConvertFrom-Json)
    $drop = @($j.wouldDrop | Where-Object { $_ })
    if ($drop.Count -gt 0) { return $drop }
  } catch { /* an unreadable report is not evidence of a problem */ }
  return $null
}

# ------------------------------------------------------------- plugin updates
function Get-PluginUpdateReport {
  $script = Join-Path $scriptDir 'dsh-updates.mjs'
  if (-not (Test-Path -LiteralPath $script)) { return $null }
  $raw = & node $script --profile $Profile --dsh $InstallDir --tag $Tag --json 2>$null
  if (-not $raw) { return $null }
  try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}

function Get-NewestPluginSnapshot([string] $tag) {
  $root = Join-Path $script:RepoRoot 'backups'
  if (-not (Test-Path -LiteralPath $root)) { return $null }
  $pattern = if ($tag) { '*-' + $tag } else { 'plugins-*' }
  $hit = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $pattern } | Sort-Object Name -Descending | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Restore-PluginSnapshot([string] $snapshotDir) {
  $script = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
  if (-not (Test-Path -LiteralPath $snapshotDir)) { Write-Bad ("snapshot is gone: " + $snapshotDir); return $false }
  Write-Warn ("restoring the plugin snapshot " + (Split-Path -Leaf $snapshotDir))
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Mode restore -Name (Split-Path -Leaf $snapshotDir) -Yes -Profile $Profile 2>&1
  $rc = $LASTEXITCODE
  $out | Where-Object { $_ -match 'restored|removed|ERROR|done' } | Select-Object -First 12 | ForEach-Object { Write-Host ("       " + $_) }
  if ($rc -ne 0) { Write-Bad "the plugin restore reported a failure"; return $false }
  return $true
}

# ------------------------------------------------------------------- context
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$bin = Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$npm = Get-NpmCmd

Write-Step ("install dir : " + $InstallDir)
Write-Step ("npm         : " + $npm)
Write-Step ("dist-tag    : @deepseek-ai/dsh@" + $Tag)

# ----------------------------------------------------------- rollback request
if ($Rollback) {
  if ($DryRun) { Write-Step "DRYRUN would restore the previous install from the backup"; exit 2 }
  if (Restore-DshInstall) {
    $check = Test-DshTree $InstallDir $Profile $null
    if ($check.Ok) { Write-Step "rollback verified"; exit 0 }
    Write-Bad ("rollback done but the install still does not verify: " + $check.Why)
    exit 1
  }
  exit 1
}

# ------------------------------------------------------- backup-only request
# Refresh the rollback point on demand (e.g. after a manual bump) without
# touching the install. Copies only - never installs, never restarts DSH.
if ($BackupOnly) {
  if ($DryRun) { Write-Step "DRYRUN would refresh the rollback point from the current install"; exit 2 }
  if (Backup-DshInstall 'manual') { exit 0 }
  Write-Bad "could not create the install backup"
  exit 1
}

# ---------------------------------------------------------------- 1. target
# Capture first, shorten after - see the note in Test-DshTree about
# Select-Object -First 1 on a live native pipeline.
$tOut = & $npm view "@deepseek-ai/dsh@$Tag" version 2>$null
$target = @($tOut) | Where-Object { $_ -and ("" + $_).Trim() } | Select-Object -First 1
if ($target) { $target = $target.Trim() }
if (-not $target) {
  Write-Warn ("could not resolve @deepseek-ai/dsh@" + $Tag + " (offline? npm broken?) - keeping the local install")
  if (-not (Test-Path $bin)) { exit 1 }
  Write-Step "starting whatever is already installed"
  exit 0
}
Write-Step ("newest      : " + $target)

# ------------------------------------------------------------- 2. installed
$before = Get-InstalledDshVersion $InstallDir
if ($before) { Write-Step ("installed   : " + $before) } else { Write-Step "installed   : (none)" }

$changed = ($before -ne $target)
$rolledBack = $false

if ($changed -and (Test-VersionSuppressed $target)) {
  Write-Warn ("skipping " + $target + " - it already failed to install or verify on this machine")
  Write-Warn ("next retry after " + $script:suppressUntil.ToString('yyyy-MM-dd HH:mm') +
              " (force it now with -IgnoreUpdateFailures)")
  $changed = $false
}

# A new DSH that would refuse to load the installed plugins is not an update
# worth having. Hold it and say exactly which plugins would be lost.
if ($changed -and -not $IgnorePluginCompat) {
  $drop = Get-PluginCompatBlock $target
  if ($drop) {
    Write-Warn ("holding " + $target + " - it would refuse to load " + $drop.Count + " of the installed plugins")
    foreach ($d in $drop) { Write-Warn ("  would be skipped: " + $d) }
    Write-Warn "staying on the current DSH so the plugins keep working"
    Write-Warn "update those plugins first, or force it with -IgnorePluginCompat"
    $changed = $false
  }
}

# ------------------------------------------------------- check-only request
# Answers "is there anything to update?" and writes NOTHING: no install, no
# snapshot, no backup. Exit 10 means yes, 0 means everything is current.
# The logon path runs this hidden so it can decide whether to show the popup.
if ($CheckOnly) {
  $need = @()
  if ($changed) { $need += ("DSH " + ("" + $before) + " -> " + $target) }
  if (-not $SkipPluginUpdate) {
    $chk = Get-PluginUpdateReport
    if ($chk -and $chk.plugins) {
      foreach ($p in @($chk.plugins.outdated)) {
        $need += ("plugin " + $p.name + " " + $p.installed + " -> " + $p.newest)
      }
    }
  }
  if ($need.Count -gt 0) {
    Write-Step "CHECK: an update is available"
    foreach ($n in $need) { Write-Step ("  " + $n) }
    exit 10
  }
  Write-Step "CHECK: everything is up to date"
  exit 0
}

if (-not $changed) {
  Write-Step "DSH is already up to date - nothing to install"
} else {
  if ($DryRun) {
    Write-Step ("DRYRUN would back up " + $InstallDir + ", then npm install --save-exact @deepseek-ai/dsh@" + $target)
  } else {
    Write-Step ("updating DSH in place: " + ("" + $before) + " -> " + $target)

    $backupDir = $null
    if (-not $SkipInstallBackup) {
      $backupDir = Backup-DshInstall 'pre-dsh-update'
      if (-not $backupDir) {
        Write-Bad "no rollback copy could be made, so the install was NOT attempted"
        Write-Bad "free some space, or re-run with -SkipInstallBackup if you accept the risk"
        exit 1
      }
    } else {
      Write-Warn "install backup skipped (-SkipInstallBackup)"
    }

    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
    $npmOut = & $npm install --no-audit --no-fund --save-exact --prefix $InstallDir "@deepseek-ai/dsh@$target" 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { $npmOut | Select-Object -Last 20 | ForEach-Object { Write-Host ("       " + $_) } }
    $after = Get-InstalledDshVersion $InstallDir
    Write-Step ("installed   : " + $after)

    if (-not (Test-Path $bin)) {
      Write-Bad "the install left no usable local copy"
      Add-FailedVersion $target
      if ($backupDir) { $null = Restore-DshInstall }
      exit 1
    }

    # npm 11 will not run a NEW dependency's install script until it has been
    # approved once, and a silently skipped native build is exactly how a
    # working DSH turns into a broken one. Approve whatever showed up and
    # rerun the builds. Verified below, so a failure here is not fatal.
    if ($rc -eq 0) {
      Push-Location $InstallDir
      try {
        Write-Step "approving dependency build scripts (npm 11 script gate)"
        $appr = & $npm install-scripts approve --all --no-allow-scripts-pin 2>&1
        $appr | Select-Object -Last 4 | ForEach-Object { Write-Host ("       " + $_) }
        if ($LASTEXITCODE -ne 0) { Write-Warn "npm install-scripts approve returned a non-zero exit code" }
        Write-Step "rebuilding dependencies"
        $reb = & $npm rebuild 2>&1
        $reb | Select-Object -Last 6 | ForEach-Object { Write-Host ("       " + $_) }
        if ($LASTEXITCODE -ne 0) { Write-Warn "npm rebuild returned a non-zero exit code - DSH may still start fine" }
      } finally {
        Pop-Location
      }
    }

    # The gate: an installed-and-run-now-broken DSH is worse than an old one.
    Write-Step "verifying the new install (version + full plugin config)"
    $check = Test-DshTree $InstallDir $Profile $target
    if ($check.Ok) {
      Write-Step ("verified    : DSH " + $check.Why + " composes the plugin tree cleanly")
    } else {
      Write-Bad ("verification failed: " + $check.Why)
      Add-FailedVersion $target
      if (-not $backupDir) {
        Write-Bad "no backup was taken, so there is nothing to roll back to"
        Write-Bad "run restore.bat / re-install manually before starting DSH"
        exit 1
      }
      if (Restore-DshInstall) { $rolledBack = $true; exit 3 }
      exit 1
    }
  }
}

# ------------------------------------------------- 3. plugins move with DSH
$report = $null
$pending = @()
if (-not $SkipPluginUpdate) {
  $report = Get-PluginUpdateReport
  if ($report -and $report.plugins) {
    $pending = @($report.plugins.outdated)
    if ($report.plugins.held) {
      foreach ($h in @($report.plugins.held)) {
        Write-Step ("waiting     : " + $h.name + " " + $h.newest + " is too new for the release-age gate (opens " + $h.eligibleAt + ")")
      }
    }
    if ($report.plugins.pinned) {
      foreach ($p in @($report.plugins.pinned)) {
        Write-Step ("pinned      : " + $p.name + " stays at " + $p.installed + "; " + $p.newest + " exists (use bump.bat)")
      }
    }
  } elseif ($report) {
    Write-Warn "the update check returned nothing usable"
  }
}

$doPlugins = ($changed -or $ForcePluginUpdate -or $pending.Count -gt 0) -and (-not $SkipPluginUpdate)
$why = @()
if ($changed) { $why += 'DSH changed' }
if ($ForcePluginUpdate) { $why += '-ForcePluginUpdate' }
if ($pending.Count -gt 0) { $why += ($pending.Count.ToString() + ' plugin(s) behind') }

if ($doPlugins) {
  Write-Step ("plugin update needed (" + ($why -join ', ') + ")")
  foreach ($p in $pending) { Write-Step ("  behind    : " + $p.name + " " + $p.installed + " -> " + $p.newest) }
  if ($DryRun) {
    Write-Step "DRYRUN would snapshot the profile and run: dsh plugin --profile $Profile update"
  } else {
    Write-Step "snapshotting the plugin profile before the update"
    $snap = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
    $snapDir = $null
    if (Test-Path $snap) {
      $snapOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $snap -Mode snapshot -Name pre-dsh-update -Profile $Profile 2>&1
      foreach ($line in $snapOut) {
        $m = [regex]::Match(("" + $line), 'snapshot created:\s*(.+?)\s+kind=')
        if ($m.Success) { $snapDir = $m.Groups[1].Value.Trim() }
      }
      if ($snapDir) {
        Write-Step ("snapshot    : " + (Split-Path -Leaf $snapDir))
      } else {
        # Fall back to the newest one the naming convention can find.
        $snapDir = Get-NewestPluginSnapshot 'pre-dsh-update'
        if ($snapDir) { Write-Warn ("could not read the snapshot path from its output; assuming " + (Split-Path -Leaf $snapDir)) }
        else { Write-Warn "the snapshot could not be located - the plugin update will not be reversible" }
      }
    } else {
      Write-Warn "backup script not found, skipping the safety snapshot"
    }

    # Was the profile healthy before we touched it? If it was already broken,
    # restoring the snapshot cannot fix it and would only hide the real cause.
    $pre = Test-DshTree $InstallDir $Profile $null

    Write-Step "updating the profile plugins"
    # Name the packages instead of a bare `pnpm update`: a full update makes
    # pnpm re-resolve plugins whose newest version the release-age gate is
    # still holding, which is how an update ends up failing for a reason that
    # has nothing to do with the plugin that actually needs updating.
    $pluginArgs = @($bin, 'plugin', '--profile', $Profile, 'update')
    $eligible = @($pending | ForEach-Object { $_.name })
    if ($eligible.Count -gt 0) { $pluginArgs += $eligible; Write-Step ("  targeting : " + ($eligible -join ', ')) }
    & node @pluginArgs 2>&1 | Select-Object -Last 25 | ForEach-Object { Write-Host ("       " + $_) }
    $pluginRc = $LASTEXITCODE
    if ($pluginRc -ne 0) { Write-Warn "plugin update returned a non-zero exit code - see the output above" }

    Write-Step "verifying the profile after the plugin update"
    $post = Test-DshTree $InstallDir $Profile $null
    if ($post.Ok) {
      Write-Step "verified    : the plugin tree still composes cleanly"
    } elseif (-not $pre.Ok) {
      Write-Bad ("the plugin tree was ALREADY broken before this update: " + $pre.Why)
      Write-Bad "restoring the snapshot would not help, so it was left alone"
      exit 1
    } else {
      Write-Bad ("verification failed: " + $post.Why)
      if ($snapDir) {
        if (Restore-PluginSnapshot $snapDir) { $rolledBack = $true; exit 3 }
      } else {
        Write-Bad "no snapshot is available, so the profile was left as it is"
        Write-Bad "restore.bat can still recover an earlier snapshot by hand"
      }
      exit 1
    }
  }
} elseif (-not $changed) {
  if ($SkipPluginUpdate) { Write-Step "plugin update skipped (-SkipPluginUpdate)" }
  else { Write-Step "plugins left alone (nothing is behind)" }
}

# ------------------------------------------------------------ 4. npx cleanup
if (-not $SkipNpxCleanup) {
  $npxRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
  if (-not (Test-Path $npxRoot)) {
    Write-Step "no leftover npx cache"
  } elseif (-not (Test-Path $bin)) {
    Write-Step "local install missing - keeping the npx cache as a fallback"
  } elseif (Test-DshServerListening $Port) {
    Write-Step ("a DSH server is listening on port " + $Port + " - leaving the npx cache alone")
  } else {
    $busy = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*_npx*' }
    if ($busy) {
      Write-Step "a node process still runs from an npx folder - leaving the npx cache alone"
    } else {
      Get-ChildItem -LiteralPath $npxRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $isDsh = Test-Path (Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\package.json')
        if ($isDsh) {
          if ($DryRun) {
            Write-Step ("DRYRUN would delete leftover copy " + $_.FullName)
          } else {
            try {
              Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
              Write-Step ("removed leftover npx copy " + $_.Name)
            } catch {
              Write-Warn ("could not remove " + $_.FullName + " - " + $_.Exception.Message)
            }
          }
        }
      }
    }
  }
}

if ($DryRun) { exit 2 }
if ($rolledBack) { exit 3 }
exit 0
