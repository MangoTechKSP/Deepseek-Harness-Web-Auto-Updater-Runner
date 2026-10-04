#requires -version 5.1
<#
  dsh-tasks.ps1  --  register / inspect / remove the DSH scheduled tasks.

    powershell -File tools\dsh-tasks.ps1              register or refresh them
    powershell -File tools\dsh-tasks.ps1 -Status      show what is registered
    powershell -File tools\dsh-tasks.ps1 -Remove      remove both tasks

  Tasks
    DSH-Boot-AutoUpdate     at logon (+45s so the network is up), runs
                            tools\dsh-boot-hidden.vbs through wscript.exe, i.e.
                            with no console window at all. That script checks
                            and installs a DSH update with automatic rollback,
                            checks plugin updates and compatibility, verifies
                            the plugin tree, and then starts DSH hidden so
                            http://127.0.0.1:3080 simply answers.
    DSH-Plugin-AutoBackup   every 15 minutes, snapshots the plugin profile when
                            it changed. Also registered through wscript.exe +
                            tools\run-hidden.vbs: running powershell.exe directly
                            from Task Scheduler makes Windows Terminal flash a
                            new window on screen every single time.

  Everything is registered for the current user with a limited token, so no
  administrator rights are needed and no UAC prompt appears at logon.
#>
[CmdletBinding()]
param(
  [switch] $Status,
  [switch] $Remove
)

. "$PSScriptRoot\dsh-common.ps1"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$vbs = Join-Path $scriptDir 'dsh-boot-hidden.vbs'
$bootTask = 'DSH-Boot-AutoUpdate'
$backupTask = 'DSH-Plugin-AutoBackup'
$staleTask = 'DSH-Web-Restart-DshMarket'

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Show-Tasks {
  Write-Host "[tasks] registered DSH tasks" -ForegroundColor Cyan
  $all = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'DSH-*' }
  if (-not $all) { Write-Host "  (none)" ; return }
  foreach ($t in $all | Sort-Object TaskName) {
    $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    $action = ($t.Actions | ForEach-Object { ($_.Execute + ' ' + $_.Arguments).Trim() }) -join ' ; '
    Write-Host ("  " + $t.TaskName + "  [" + $t.State + "]")
    Write-Host ("      trigger : " + (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '))
    Write-Host ("      action  : " + $action)
    if ($info) { Write-Host ("      last    : " + $info.LastRunTime + "  result " + $info.LastTaskResult + "   next " + $info.NextRunTime) }
  }
}

if ($Status) { Show-Tasks; exit 0 }

if ($Remove) {
  foreach ($name in @($bootTask, $backupTask)) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $name -Confirm:$false
      Write-Host ("[tasks] removed " + $name) -ForegroundColor Yellow
    }
  }
  Show-Tasks
  exit 0
}

# ------------------------------------------------------- stale task cleanup
# A leftover task pointed at WorkSpace\dsh-restart.ps1, a script that no longer
# exists. It could never start anything again, so it is removed here.
if (Get-ScheduledTask -TaskName $staleTask -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $staleTask -Confirm:$false
  Write-Host ("[tasks] removed the stale task " + $staleTask) -ForegroundColor Yellow
}

# --------------------------------------------------------- boot task
if (-not (Test-Path -LiteralPath $vbs)) {
  Write-Host ("[tasks] " + $vbs + " is missing - cannot register the boot task") -ForegroundColor Red
  exit 1
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') -WorkingDirectory $repoRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
# Give the network and the shell a moment before npm is asked anything.
try { $trigger.Delay = 'PT45S' } catch { Write-Host "[tasks] note: could not set the logon delay" -ForegroundColor Yellow }
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

try {
  $null = Register-ScheduledTask -TaskName $bootTask -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force -ErrorAction Stop
  Write-Host ("[tasks] registered " + $bootTask + " (at logon, +45s, hidden)") -ForegroundColor Green
} catch {
  Write-Host ("[tasks] could not register " + $bootTask + ": " + $_.Exception.Message) -ForegroundColor Red
  Write-Host "[tasks] fallback: put a shortcut to tools\dsh-boot-hidden.vbs in" -ForegroundColor Yellow
  Write-Host ('        ' + (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')) -ForegroundColor Yellow
  exit 1
}

# --------------------------------------------------------- backup task
# schtasks is used here (not Register-ScheduledTask) because /sc minute /mo 15
# produces the indefinite 15-minute repetition we want without the
# -RepetitionDuration quirks of the ScheduledTasks module.
$backupLauncher = Join-Path $scriptDir 'run-hidden.vbs'
$backupScript   = Join-Path $scriptDir 'dsh-plugin-backup.ps1'
if ((Test-Path -LiteralPath $backupLauncher) -and (Test-Path -LiteralPath $backupScript)) {
  $tr = 'wscript.exe ' + $backupLauncher + ' dsh-plugin-backup.ps1 -Mode auto'
  $out = & cmd /c ('schtasks /create /tn "' + $backupTask + '" /tr "' + $tr + '" /sc minute /mo 15 /f 2>&1')
  if ($LASTEXITCODE -eq 0) {
    Write-Host ("[tasks] registered " + $backupTask + " (every 15 min, hidden)") -ForegroundColor Green
  } else {
    Write-Host ("[tasks] could not register " + $backupTask) -ForegroundColor Red
    $out | ForEach-Object { Write-Host ("        " + $_) }
  }
} else {
  Write-Host "[tasks] run-hidden.vbs or dsh-plugin-backup.ps1 is missing - the backup task was left alone" -ForegroundColor Yellow
}

Show-Tasks
exit 0
