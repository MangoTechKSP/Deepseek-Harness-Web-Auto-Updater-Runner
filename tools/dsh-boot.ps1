#requires -version 5.1
<#
  dsh-boot.ps1  --  silent start-up brain: pre-flight, then start DSH.

  Two modes, both of which are safe to run while another DSH is serving:

    -Mode preflight   what run.bat calls before it starts DSH:
                        1. snapshot the plugin profile if anything changed
                        2. check npm for a newer DSH, install it in place,
                           verify it, roll back automatically on failure
                        3. report plugin updates and pnpm release-age holds
                        4. check every plugin for offline compatibility
                        5. verify the whole plugin tree still composes; if it
                           does not, drop the plugins that break it and verify
                           again
                      Exits 0 when it is safe to start DSH, 1 when it is not.

                      With -PromptUpdate, step 2 is gated behind a dialog:
                      the check runs silently first and only a real pending
                      update produces a Yes/No prompt. -AssumeYes skips the
                      question (the logon popup already asked).

    -Mode launch      what the logon task calls. If port 3080 is free it runs
                      run.bat in a hidden window and waits for the server to
                      answer, so that simply typing http://127.0.0.1:3080 in a
                      browser works. If the port is already served it does
                      nothing at all.

                      Before starting, it checks for updates quietly. Nothing
                      behind -> silent start, no browser. Something behind ->
                      a Yes/No dialog; "yes" hands over to a VISIBLE run.bat
                      that updates, starts the server and then opens the
                      browser, "no" starts silently on the current version.

  Everything it prints also goes to logs\boot.log
#>
[CmdletBinding()]
param(
  [ValidateSet('preflight', 'launch')]
  [string] $Mode = 'preflight',
  [int]    $Port = 3080,
  [string] $Profile = 'web',
  [string] $Tag = 'latest',
  [string] $InstallDir,
  [int]    $WaitSeconds = 120,
  [switch] $ForcePluginUpdate,
  [switch] $SkipUpdate,
  [switch] $SkipBackup,
  [switch] $PromptUpdate,
  [switch] $AssumeYes,
  [switch] $DryRun
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
if (-not $InstallDir) { $InstallDir = Join-Path $repoRoot 'dsh' }

$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir 'boot.log'
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\dsh-common.ps1"

function Write-Log([string] $text, [string] $colour = 'Gray') {
  $line = ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + (T-Line $text))
  Write-Host $line -ForegroundColor $colour
  try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

function Test-DshServerListening([int] $port) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
    return [bool]$c
  } catch {
    $hit = netstat -ano | Select-String -SimpleMatch (":" + $port + " ") | Select-String -SimpleMatch 'LISTENING'
    return [bool]$hit
  }
}

function Test-DshTree([string] $dir, [string] $profile) {
  $b = Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path -LiteralPath $b)) { return [pscustomobject]@{ Ok = $false; Why = 'lib\bin.js is missing' } }
  $cfg = & node $b --profile $profile --dump-config 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    return [pscustomobject]@{ Ok = $false; Why = ("--dump-config exited " + $rc + ": " + ((($cfg | Select-Object -Last 8) -join ' | '))) }
  }
  return [pscustomobject]@{ Ok = $true; Why = 'the plugin tree composes cleanly' }
}

function Get-Bin { return (Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js') }

# Ask dsh-update.ps1 whether anything is behind, without letting it write.
# Returns $null when the question could not be answered at all (offline, npm
# broken, script missing) - the caller must then fall back to a normal run.
function Get-UpdateCheck {
  $updater = Join-Path $scriptDir 'dsh-update.ps1'
  if (-not (Test-Path -LiteralPath $updater)) { return $null }
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater, '-CheckOnly',
    '-Tag', $Tag, '-Profile', $Profile, '-Port', ([string]$Port), '-InstallDir', $InstallDir)
  $out = & powershell @argv 2>&1
  $rc = $LASTEXITCODE
  $lines = @($out | ForEach-Object { ("" + $_).Trim() } | Where-Object { $_ })
  return [pscustomobject]@{ Available = ($rc -eq 10); Rc = $rc; Lines = $lines }
}

# The update dialog. ask-update.vbs draws it through wscript.exe, which is a
# GUI-subsystem program: no console is ever allocated for it, so asking the
# question cannot flash a window the way a powershell -Command call would.
# 6 = yes, 7 = no (or the dialog timed out). Anything else means "not now".
function Confirm-DshUpdate {
  $vbs = Join-Path $scriptDir 'ask-update.vbs'
  if (-not (Test-Path -LiteralPath $vbs)) {
    Write-Log "prompt: ask-update.vbs is missing - not updating" 'Yellow'
    return $false
  }
  try {
    $sec = if ($env:DSH_POPUP_TIMEOUT) { $env:DSH_POPUP_TIMEOUT } else { '90' }
    $argv = @(
      ('"' + $vbs + '"'),
      ('"' + (T 'DSH update check') + '"'),
      ('"' + (T 'An update is available for DSH.') + '"'),
      ('"' + (T 'Yes - update now. A window opens showing the update, and the browser opens automatically when it is verified.') + '"'),
      ('"' + (T 'No - start the version that is installed now. You will be asked again next time.') + '"'),
      ('"' + (T 'Clicking nothing will be treated as No.') + '"'),
      ('"' + $sec + '"')
    )
    $p = Start-Process -FilePath 'wscript.exe' -ArgumentList $argv -Wait -PassThru
  } catch {
    Write-Log ("prompt: could not show the dialog (" + $_.Exception.Message + ") - not updating") 'Yellow'
    return $false
  }
  switch ($p.ExitCode) {
    6 { Write-Log "prompt: the user chose to update now" 'Green'; return $true }
    7 { Write-Log "prompt: the user chose not to update now" 'Yellow'; return $false }
    default {
      Write-Log ("prompt: unexpected answer " + $p.ExitCode + " - not updating") 'Yellow'
      return $false
    }
  }
}

function Invoke-LoggedPowershell {
  param([string[]] $Argv, [string] $Prefix = '  update | ')
  $out = & powershell @Argv 2>&1
  $rc = $LASTEXITCODE
  foreach ($line in $out) { if (("" + $line).Trim()) { Write-Log ($Prefix + $line) 'DarkGray' } }
  return $rc
}

# ============================================================== launch mode
if ($Mode -eq 'launch') {
  Write-Log "boot: logon launch requested (port $Port)" 'Cyan'
  if (Test-DshServerListening $Port) {
    Write-Log "boot: something is already listening on port $Port - leaving it alone"
    exit 0
  }
  $runBat = Join-Path $repoRoot 'run.bat'
  if (-not (Test-Path -LiteralPath $runBat)) {
    Write-Log "boot: run.bat is missing, nothing to launch" 'Red'
    exit 1
  }

  # ---- is an update waiting? ask BEFORE anything starts -------------------
  # This is the whole point of the dialog: an automatic start must never
  # update behind the user's back. Nothing is installed unless they say yes.
  $approved = $false
  $declined = $false
  $chk = Get-UpdateCheck
  if (-not $chk) {
    Write-Log "boot: could not check for updates - starting normally" 'Yellow'
  } elseif ($chk.Available) {
    foreach ($line in $chk.Lines) { Write-Log ("  check | " + $line) 'DarkGray' }
    Write-Log "boot: an update is available - asking the user" 'Yellow'
    if (Confirm-DshUpdate) { $approved = $true } else { $declined = $true }
  } else {
    Write-Log "boot: nothing is behind - starting quietly"
  }

  if ($approved) {
    # Hand the whole job to a VISIBLE run.bat: the user asked for the update
    # and should be able to watch it. That window does the install, verifies
    # it, starts the server and only then opens the browser.
    $cmd = 'set "DSH_UPDATE_APPROVED=1" && "' + $runBat + '"'
    Write-Log "boot: starting run.bat in a visible window (approved update; the browser opens when it is up)" 'Green'
    $null = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/c', $cmd -WindowStyle Normal
    exit 0
  }

  $runLog = Join-Path $logDir 'run.log'
  $stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Add-Content -LiteralPath $runLog -Value ("`r`n===== " + $stamp + " hidden launch =====") -Encoding UTF8
  # run.bat keeps its own port guard, runs the same pre-flight and only then
  # starts the server, so this reuses the path a human would take.
  # DSH_OPEN_BROWSER=0 is forced here: an automatic logon start must never pop a
  # browser window at the user (open http://127.0.0.1:3080 yourself instead).
  # DSH_NO_PAUSE=1 keeps a hidden start from ever blocking on a keypress.
  # DSH_UPDATE_DECLINED / _APPROVED carry the answer given to the dialog above.
  $pre = ''
  if ($declined) { $pre = 'set "DSH_UPDATE_DECLINED=1" && ' }
  $cmd = $pre + 'set "DSH_NO_PAUSE=1" && set "DSH_OPEN_BROWSER=0" && ' + '"' + $runBat + '" >> "' + $runLog + '" 2>&1'
  Write-Log "boot: starting run.bat hidden (output to logs\run.log)"
  $null = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/c', $cmd -WindowStyle Hidden

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  $up = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    if (Test-DshServerListening $Port) { $up = $true; break }
  }
  if ($up) {
    Write-Log ("boot: DSH is serving http://127.0.0.1:" + $Port) 'Green'
    exit 0
  }
  Write-Log ("boot: DSH did not answer on port $Port within " + $WaitSeconds + "s") 'Red'
  $tail = @()
  if (Test-Path -LiteralPath $runLog) { $tail = Get-Content -LiteralPath $runLog -Tail 15 -ErrorAction SilentlyContinue }
  foreach ($l in $tail) { Write-Log ("  run.log | " + $l) 'DarkYellow' }
  exit 1
}

# ============================================================ preflight mode
$failed = $false
Write-Log ("preflight: DSH start-up check (profile " + $Profile + ", tag " + $Tag + ", port " + $Port + ")") 'Cyan'

# ---- 1. snapshot the plugin set when it changed since the last snapshot ----
if (-not $SkipBackup) {
  $backup = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
  if (Test-Path -LiteralPath $backup) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $backup -Mode auto -Profile $Profile 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in $out) { if (("" + $line).Trim()) { Write-Log ("  backup | " + $line) 'DarkGray' } }
    switch ($rc) {
      0 { Write-Log "snapshot: a new plugin snapshot was taken" }
      2 { Write-Log "snapshot: nothing changed since the last one (or pnpm is busy)" }
      default { Write-Log ("snapshot: the backup step returned " + $rc) 'Yellow' }
    }
  } else {
    Write-Log "snapshot: dsh-plugin-backup.ps1 not found - skipped" 'Yellow'
  }
} else {
  Write-Log "snapshot: skipped (-SkipBackup)"
}

# ------------------------------------------------- 2. DSH itself, safe to fail
if (-not $SkipUpdate) {
  $updater = Join-Path $scriptDir 'dsh-update.ps1'
  if (-not (Test-Path -LiteralPath $updater)) {
    Write-Log "update: dsh-update.ps1 not found - skipped" 'Yellow'
  } else {
    # An update is only ever performed with the user's consent. First ask the
    # cheap, write-free question ("is anything behind?"), then ask the human -
    # and only if BOTH answers are yes does the updater run.
    $runUpdate = $true
    if ($AssumeYes) {
      Write-Log "update: -AssumeYes, this update was already approved" 'Green'
    } else {
      $chk = Get-UpdateCheck
      if (-not $chk) {
        Write-Log "update: could not check for updates - running the updater as before" 'Yellow'
      } else {
        foreach ($line in $chk.Lines) { Write-Log ("  check | " + $line) 'DarkGray' }
        if (-not $chk.Available) {
          Write-Log "update: nothing is behind - no question, no install"
        } elseif (-not $PromptUpdate) {
          Write-Log "update: an update is available and nobody was asked (-PromptUpdate not given)" 'Yellow'
        } elseif (Confirm-DshUpdate) {
          Write-Log "update: the user approved the update" 'Green'
        } else {
          Write-Log "update: the user declined the update - starting the current version" 'Yellow'
          $runUpdate = $false
        }
      }
    }

    if ($runUpdate) {
      $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater,
        '-Tag', $Tag, '-Profile', $Profile, '-Port', ([string]$Port), '-InstallDir', $InstallDir)
      if ($ForcePluginUpdate) { $argv += '-ForcePluginUpdate' }
      if ($DryRun) { $argv += '-DryRun' }
      $rc = Invoke-LoggedPowershell -Argv $argv
      switch ($rc) {
        0 { Write-Log "update: DSH is up to date or was updated successfully" }
        2 { Write-Log "update: dry run, nothing was written" 'Yellow' }
        3 { Write-Log "update: an update was installed, failed verification and was rolled back" 'Red' }
        default { Write-Log ("update: the updater exited with " + $rc) 'Yellow' }
      }
    } else {
      Write-Log "update: skipped for this run"
    }
  }
} else {
  Write-Log "update: skipped (-SkipUpdate)"
}

# ------------------------------------------- 3. plugin compatibility, offline
$health = Join-Path $scriptDir 'dsh-plugin-health.mjs'
if (Test-Path -LiteralPath $health) {
  $out = & node $health --profile $Profile --dsh $InstallDir 2>&1
  foreach ($line in $out) { if (("" + $line).Trim()) { Write-Log ("  health | " + $line) } }
} else {
  Write-Log "health: dsh-plugin-health.mjs not found - skipped" 'Yellow'
}

# ------------------------------ 4. can the whole tree actually be composed?
$check = Test-DshTree $InstallDir $Profile
if ($check.Ok) {
  Write-Log ("verify: " + $check.Why) 'Green'
  exit 0
}

Write-Log ("verify: " + $check.Why) 'Red'
Write-Log "verify: dropping the plugins that keep the tree from composing, then retrying once" 'Yellow'
if ($DryRun) {
  Write-Log "verify: DRYRUN would run dsh-plugin-health.mjs --remove" 'Yellow'
  exit 1
}
if (Test-Path -LiteralPath $health) {
  $out = & node $health --profile $Profile --dsh $InstallDir --remove 2>&1
  foreach ($line in $out) { if (("" + $line).Trim()) { Write-Log ("  remove | " + $line) } }
}
$retry = Test-DshTree $InstallDir $Profile
if ($retry.Ok) {
  Write-Log ("verify: fixed - " + $retry.Why) 'Green'
  Write-Log "verify: the removed plugin is in the newest snapshot; restore.bat brings it back" 'Yellow'
  exit 0
}

Write-Log ("verify: still broken - " + $retry.Why) 'Red'
Write-Log "verify: DSH was NOT started, because it cannot compose its plugin tree" 'Red'
Write-Log "verify: fix it with either of these, then run run.bat again" 'Red'
Write-Log "verify:   restore.bat          put the plugin set back to an earlier snapshot" 'Red'
Write-Log "verify:   DSH_SKIP_UPDATE=1 run.bat   start without the update step" 'Red'
exit 1
