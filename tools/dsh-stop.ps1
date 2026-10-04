#requires -version 5.1
<#
  dsh-stop.ps1  --  stop the DSH Web server that is listening on a port.

  Safety rules, because "stop the thing on port 3080" is a dangerous sentence:
    * only a process named node.exe is ever killed
    * its command line must mention dsh (lib\bin.js or dsh web); anything else
      on that port is reported and left running
    * the whole process tree goes, so the dsh-subprocess-local runners and
      plugin sidecars started by DSH do not outlive it
    * the billion-context sidecar is stopped too when it is clearly that
      plugin's node process, because a stale one keeps its port and makes the
      next DSH start fail

  Exit codes: 0 = port free, 1 = something is still listening.
#>
[CmdletBinding()]
param(
  [int]    $Port = 3080,
  [int]    $TimeoutSeconds = 25,
  [switch] $DryRun
)

. "$PSScriptRoot\dsh-common.ps1"

$ErrorActionPreference = 'Continue'

function Get-Listener([int] $port) {
  $pids = @()
  try {
    $pids = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop |
      Select-Object -ExpandProperty OwningProcess -Unique)
  } catch {
    foreach ($line in (netstat -ano | Select-String -SimpleMatch (":" + $port + " ") | Select-String -SimpleMatch 'LISTENING')) {
      $m = [regex]::Match(("" + $line), '\s+(\d+)\s*$')
      if ($m.Success) { $pids += [int]$m.Groups[1].Value }
    }
    $pids = @($pids | Select-Object -Unique)
  }
  return $pids
}

function Test-DshListener([int] $port) { return ((Get-Listener $port).Count -gt 0) }

Write-Host ("[stop] port " + $Port)

if (-not (Test-DshListener $Port)) {
  Write-Host "[stop] nothing is listening on that port"
} else {
  foreach ($procId in (Get-Listener $Port)) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host ("[stop] pid " + $procId + " vanished"); continue }
    $cmdline = ''
    try { $cmdline = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $procId) -ErrorAction Stop).CommandLine } catch { }
    if ($p.ProcessName -ne 'node') {
      Write-Host ("[stop] pid " + $procId + " on port " + $Port + " is " + $p.ProcessName + ", not node - refusing to touch it") -ForegroundColor Yellow
      continue
    }
    if ($cmdline -notmatch 'dsh') {
      Write-Host ("[stop] pid " + $procId + " is node but does not look like DSH - refusing to touch it") -ForegroundColor Yellow
      Write-Host ("        " + $cmdline) -ForegroundColor DarkGray
      continue
    }
    if ($DryRun) {
      Write-Host ("[stop] DRYRUN would kill pid " + $procId + " and its children") -ForegroundColor Yellow
      continue
    }
    Write-Host ("[stop] stopping DSH pid " + $procId + " (tree)")
    $null = & taskkill /PID $procId /T /F 2>&1
  }
}

# The billion-context plugin runs its own node sidecar; if a previous DSH died
# without cleaning up, that sidecar keeps port 5119 and the next start fails.
foreach ($sidecar in (Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*billion-context*' })) {
  if ($DryRun) {
    Write-Host ("[stop] DRYRUN would stop the billion-context sidecar pid " + $sidecar.ProcessId) -ForegroundColor Yellow
  } else {
    Write-Host ("[stop] stopping the billion-context sidecar pid " + $sidecar.ProcessId)
    $null = & taskkill /PID $sidecar.ProcessId /T /F 2>&1
  }
}

# Wait for the port to actually go away before reporting success.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
if (-not $DryRun) {
  while ((Get-Date) -lt $deadline -and (Test-DshListener $Port)) { Start-Sleep -Milliseconds 400 }
}

if (Test-DshListener $Port) {
  Write-Host ("[stop] port " + $Port + " is STILL listening - something refused to die") -ForegroundColor Red
  exit 1
}
Write-Host ("[stop] port " + $Port + " is free") -ForegroundColor Green
exit 0
