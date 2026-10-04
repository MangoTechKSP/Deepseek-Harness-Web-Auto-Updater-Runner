# dsh-settings.ps1 -- the control panel behind settings.bat.
#
# Everything a normal user may want to change: language, port, profile,
# update channel, the two toggles, the scheduled tasks, and one-shot actions
# (check now / back up now / restore / status / install).
[CmdletBinding()]
param()

. "$PSScriptRoot\dsh-common.ps1"
$ErrorActionPreference = 'Continue'

$keys = @('lang', 'port', 'profile', 'tag', 'openBrowser', 'promptUpdate', 'backupKeep')

function Read-Settings { return Get-DshSettings }
function Save-Key([string]$key, $value) {
  $s = Read-Settings
  $o = [ordered]@{}
  foreach ($k in $keys) { $o[$k] = $s.$k }
  $o[$key] = $value
  Save-DshSettings ([pscustomobject]$o)
  Initialize-DshLang | Out-Null
}
function YesNo($v) { if ($v -eq $true -or "$v" -eq 'True' -or "$v" -eq '1') { T 'yes' } else { T 'no' } }

function Get-Languages {
  $list = New-Object System.Collections.ArrayList
  [void]$list.Add('en')
  Get-ChildItem -LiteralPath (Join-Path (Get-DshRoot) 'lang') -Filter '*.txt' -ErrorAction SilentlyContinue |
    ForEach-Object { $n = [System.IO.Path]::GetFileNameWithoutExtension($_.Name); if ($n -ne 'en' -and -not $n.StartsWith('_')) { [void]$list.Add($n) } }
  return $list
}
function Task-State([string]$name) {
  $out = & schtasks /query /tn $name /fo list 2>$null
  if ($LASTEXITCODE -eq 0) { return (T 'registered') }
  return (T 'not registered')
}

function Show-Menu {
  $s = Read-Settings
  Write-Host ''
  Write-Host ("DSH Auto-Update - settings") -ForegroundColor Cyan
  Write-Host ("Current: ") -NoNewline
  Write-Host ("lang $($s.lang)  |  port $($s.port)  |  profile $($s.profile)  |  channel $($s.tag)  |  browser $(YesNo $s.openBrowser)  |  ask $(YesNo $s.promptUpdate)")
  Write-Host ("  " + (T 'Boot task: check for updates at logon') + " : " + (Task-State 'DSH-Boot-AutoUpdate'))
  Write-Host ("  " + (T 'Auto-backup task (every 15 min)') + " : " + (Task-State 'DSH-Plugin-AutoBackup'))
  Write-Host ''
  $rows = @(
    @('1',  'Language',                            $s.lang),
    @('2',  'Web port',                            $s.port),
    @('3',  'DSH profile',                         $s.profile),
    @('4',  'Update channel',                      $s.tag),
    @('5',  'Open the browser on a manual start',  (YesNo $s.openBrowser)),
    @('6',  'Ask before an update is installed',   (YesNo $s.promptUpdate)),
    @('7',  'Check for updates now',               ''),
    @('8',  'Back up the plugins now',             ''),
    @('9',  'List backups and restore',            ''),
    @('10', 'Show status',                         ''),
    @('11', 'Install or repair DSH in this folder',''),
    @('12', 'Register both scheduled tasks',       ''),
    @('13', 'Remove both scheduled tasks',         ''),
    @('0',  'Exit',                                '')
  )
  foreach ($r in $rows) {
    $label = T $r[1]
    $val = if ($r[2] -ne '') { " ($($r[2]))" } else { '' }
    Write-Host ("  {0,2}  {1}{2}" -f $r[0], $label, $val)
  }
}

function Run-Tool([string]$file, [string[]]$argv) {
  Write-Host ''
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $file) @argv
  return $LASTEXITCODE
}

while ($true) {
  Show-Menu
  $choice = (Read-Host (T 'Choice:')).Trim()
  switch ($choice) {
    '1' {
      $langs = @('auto') + @(Get-Languages)
      Write-Host ("  " + (($langs) -join ' / '))
      Write-Host ("  " + (T 'auto = follow the system language')) -ForegroundColor DarkGray
      $v = (Read-Host (T 'Language')).Trim()
      if ($v) { Save-Key 'lang' $v; Write-Host ("  " + (T 'Settings saved to ') + $script:SettingsPath) -ForegroundColor Green }
    }
    '2' {
      $v = (Read-Host 'Web port').Trim()
      $n = 0
      if ([int]::TryParse($v, [ref]$n) -and $n -gt 0 -and $n -lt 65536) { Save-Key 'port' $n; Write-Host ("  " + (T 'Settings saved to ') + $script:SettingsPath) -ForegroundColor Green }
      else { Write-Host ("  " + (T 'Unknown choice: ') + $v) -ForegroundColor Yellow }
    }
    '3' { $v = (Read-Host 'DSH profile').Trim(); if ($v) { Save-Key 'profile' $v } }
    '4' {
      Write-Host "  latest / next / alpha / an exact version"
      $v = (Read-Host 'Update channel').Trim()
      if ($v) { Save-Key 'tag' $v }
    }
    '5' { $s = Read-Settings; Save-Key 'openBrowser' (-not ($s.openBrowser -eq $true -or "$($s.openBrowser)" -eq 'True')) }
    '6' { $s = Read-Settings; Save-Key 'promptUpdate' (-not ($s.promptUpdate -eq $true -or "$($s.promptUpdate)" -eq 'True')) }
    '7' {
      $s = Read-Settings
      $rc = Run-Tool 'dsh-update.ps1' @('-CheckOnly', '-Profile', $s.profile, '-Port', "$($s.port)", '-Tag', $s.tag)
      Write-Host ("  exit " + $rc + $(if ($rc -eq 10) { '  ->  ' + (T 'CHECK: an update is available') } else { '' })) -ForegroundColor Cyan
    }
    '8' {
      $s = Read-Settings
      Run-Tool 'dsh-plugin-backup.ps1' @('-Mode', 'snapshot', '-Profile', $s.profile, '-Keep', "$($s.backupKeep)") | Out-Null
    }
    '9' {
      $s = Read-Settings
      Run-Tool 'dsh-plugin-backup.ps1' @('-Mode', 'list', '-Profile', $s.profile) | Out-Null
      $name = (Read-Host (T 'Type the number of the backup to restore, or press Enter to cancel:')).Trim()
      if ($name) {
        Run-Tool 'dsh-plugin-backup.ps1' @('-Mode', 'restore', '-Name', $name, '-Yes', '-Profile', $s.profile) | Out-Null
      }
    }
    '10' {
      Write-Host ''
      Write-Host ("  folder      : " + (Get-DshRoot))
      Write-Host ("  install dir : " + (Get-DshInstallDir))
      Write-Host ("  DSH version : " + (Get-DshInstalledVersion))
      Write-Host ("  DSH home    : " + (Get-DshHome))
      $s = Read-Settings
      Write-Host ("  profile dir : " + (Get-ProfileDir $s.profile))
      Write-Host ("  node        : " + (& node -v) + "   npm " + (& npm -v))
      Write-Host ("  boot task   : DSH-Boot-AutoUpdate  " + (Task-State 'DSH-Boot-AutoUpdate'))
      Write-Host ("  backup task : DSH-Plugin-AutoBackup  " + (Task-State 'DSH-Plugin-AutoBackup'))
      $bk = Join-Path (Get-DshRoot) 'backups'
      if (Test-Path -LiteralPath $bk) {
        $n = @(Get-ChildItem -LiteralPath $bk -Directory -ErrorAction SilentlyContinue).Count
        Write-Host ("  backups     : $n in " + $bk)
      }
      Read-Host (T 'Press Enter to return to the menu...') | Out-Null
    }
    '11' {
      $s = Read-Settings
      Run-Tool 'dsh-setup.ps1' @('-Profile', $s.profile, '-Tag', $s.tag) | Out-Null
      Read-Host (T 'Press Enter to return to the menu...') | Out-Null
    }
    '12' { Run-Tool 'dsh-tasks.ps1' @() | Out-Null }
    '13' { Run-Tool 'dsh-tasks.ps1' @('-Remove') | Out-Null }
    '0' { exit 0 }
    default { Write-Host ("  " + (T 'Unknown choice: ') + $choice) -ForegroundColor Yellow }
  }
}
