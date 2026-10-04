# dsh-common.ps1 -- shared helpers: portable paths, settings.json, i18n.
#
# Every path is derived from this file's own location ($PSScriptRoot), so the
# whole folder can be copied, renamed or moved to any drive and still work.
# The only machine-specific thing you legitimately need is your DSH home
# (%USERPROFILE%\.dsh unless DSH_HOME says otherwise).
#
# Translation model: the English sentence IS the key. lang\<name>.txt holds
# lines of the form
#     exact|English sentence|Translated sentence
#     sub|English fragment|Translated fragment
# "exact" matches a whole line, "sub" replaces every occurrence of a fragment
# inside a longer line (used for "label : value" output). Anything not listed
# falls through unchanged, which is why en needs no file at all.

$script:DshRoot      = Split-Path -Parent $PSScriptRoot
$script:ToolDir      = $PSScriptRoot
$script:LangDir      = Join-Path $script:DshRoot 'lang'
$script:SettingsPath = Join-Path $script:DshRoot 'settings.json'

function Get-DshRoot { return $script:DshRoot }

function Get-DshSettings {
  $defaults = [ordered]@{
    lang         = ''
    port         = 3080
    profile      = 'web'
    tag          = 'latest'
    openBrowser  = $true
    promptUpdate = $true
    backupKeep   = 10
  }
  if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return [pscustomobject]$defaults }
  try {
    $raw = (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    $o = $raw | ConvertFrom-Json
  } catch { return [pscustomobject]$defaults }
  $out = [ordered]@{}
  foreach ($k in $defaults.Keys) {
    $p = $o.PSObject.Properties[$k]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { $out[$k] = $p.Value } else { $out[$k] = $defaults[$k] }
  }
  return [pscustomobject]$out
}

function Save-DshSettings($obj) {
  $json = $obj | ConvertTo-Json -Depth 4
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($script:SettingsPath, $json + "`r`n", $enc)
}

function Get-DshHome {
  if ($env:DSH_HOME -and $env:DSH_HOME.Trim() -ne '') { return $env:DSH_HOME.Trim() }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Get-DshInstallDir { return (Join-Path $script:DshRoot 'dsh') }
function Get-DshBin { return (Join-Path (Get-DshInstallDir) 'node_modules\@deepseek-ai\dsh\lib\bin.js') }
function Get-ProfileDir([string]$profile) { return (Join-Path (Join-Path (Get-DshHome) 'profiles') $profile) }

# ------------------------------------------------------------------ i18n
$script:ExactMap = @{}
$script:SubRules = @()
$script:LangName = 'en'

function Get-DshLang {
  # env wins (handy for one-off runs), then settings.json, then the OS UI language.
  if ($env:DSH_LANG -and $env:DSH_LANG.Trim() -ne '') { return $env:DSH_LANG.Trim() }
  $want = "$((Get-DshSettings).lang)".Trim()
  # "auto" means the same as leaving it empty: follow the system UI language.
  if ($want -and $want -ne 'auto') { return $want }
  try { return [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch { return 'en' }
}

function Initialize-DshLang {
  $want = Get-DshLang
  $tries = New-Object System.Collections.ArrayList
  [void]$tries.Add($want)
  if ($want -match '[-_]') { [void]$tries.Add(($want -split '[-_]')[0]) }
  [void]$tries.Add('en')
  $script:ExactMap = @{}
  $script:SubRules = @()
  foreach ($name in $tries) {
    if (-not $name) { continue }
    $file = Join-Path $script:LangDir ($name + '.txt')
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $script:LangName = $name
    if ($name -eq 'en') { return 'en' }   # English is the source text: nothing to load
    $subs = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)) {
      if (-not $line -or $line.StartsWith('#')) { continue }
      $parts = $line.Split('|')
      if ($parts.Count -lt 3) { continue }
      $kind = $parts[0].Trim()
      $from = $parts[1]
      $to = $parts[2]
      if ($kind -eq 'exact') { $script:ExactMap[(Collapse-Space $from).ToLowerInvariant()] = $to }
      elseif ($kind -eq 'sub') {
        # Scripts pad labels to align them ("npm         : ..."), so a run of
        # spaces in a rule matches any run of whitespace in the output.
        $re = [regex]::Escape($from)
        $re = [regex]::Replace($re, '(\\ )+', '\s+')
        [void]$subs.Add([pscustomobject]@{ from = $from; to = $to; re = $re })
      }
    }
    # Longest fragment first, so "install backup ready" wins over "install backup".
    $script:SubRules = @($subs | Sort-Object { - ($_.from.Length) })
    return $name
  }
  $script:LangName = 'en'
  return 'en'
}

function Get-DshLangName { return $script:LangName }

# Collapse a run of spaces to one, so padded labels compare equal.
function Collapse-Space([string]$s) { if ($null -eq $s) { return '' }; return ([regex]::Replace($s, '\s+', ' ')).Trim() }

# Translate one already-formatted line, keeping its leading indentation.
function T-Line([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  if ($script:ExactMap.Count -eq 0 -and $script:SubRules.Count -eq 0) { return $s }
  # Keep any leading whitespace AND a "[dsh] "/"[health] " style tag out of the
  # lookup, so one rule can translate a sentence printed by any script.
  $lead = ''
  $body = $s
  $m = [regex]::Match($s, '^(\s*)(\[[A-Za-z][A-Za-z-]*\]\s+)?(.*)$')
  if ($m.Success) { $lead = $m.Groups[1].Value + $m.Groups[2].Value; $body = $m.Groups[3].Value }
  $hit = $script:ExactMap[(Collapse-Space $body).ToLowerInvariant()]
  if ($hit) { return $lead + $hit }
  foreach ($r in $script:SubRules) {
    if ([regex]::IsMatch($body, $r.re, 'IgnoreCase')) { $body = [regex]::Replace($body, $r.re, $r.to, 'IgnoreCase') }
  }
  return $lead + $body
}

# Translate a standalone string (menu entries, prompts, popups).
function T([string]$s) { return (T-Line $s) }

# ------------------------------------------------------------- console
# Shadow the cmdlet so ANY line printed by ANY script that dot-sources this
# file is translated, including scripts that call Write-Host directly. Scripts
# which already translate keep working: T-Line is a no-op on text it cannot
# match, and Chinese output never matches an English rule.
function Write-Host {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] $Object,
    [string] $ForegroundColor,
    [string] $BackgroundColor,
    [switch] $NoNewline
  )
  $msg = if ($null -eq $Object) { '' } else { (@($Object) | ForEach-Object { "$_" }) -join ' ' }
  $p = @{ Object = (T-Line $msg) }
  if ($ForegroundColor) { $p['ForegroundColor'] = $ForegroundColor }
  if ($BackgroundColor) { $p['BackgroundColor'] = $BackgroundColor }
  if ($NoNewline) { $p['NoNewline'] = $true }
  Microsoft.PowerShell.Utility\Write-Host @p
}

function Write-Ok([string]$s)   { Microsoft.PowerShell.Utility\Write-Host (T-Line $s) -ForegroundColor Green }
function Write-Info([string]$s) { Microsoft.PowerShell.Utility\Write-Host (T-Line $s) }
function Write-Warn2([string]$s){ Microsoft.PowerShell.Utility\Write-Host (T-Line $s) -ForegroundColor Yellow }
function Write-Bad2([string]$s) { Microsoft.PowerShell.Utility\Write-Host (T-Line $s) -ForegroundColor Red }

function Test-DshInstalled { return (Test-Path -LiteralPath (Get-DshBin)) }

function Get-DshInstalledVersion {
  $bin = Get-DshBin
  if (-not (Test-Path -LiteralPath $bin)) { return $null }
  try {
    $out = & node $bin --version 2>&1
    $code = $LASTEXITCODE
    $line = @($out | Where-Object { "$_".Trim() -ne '' })[0]
    if ($code -eq 0 -and $line) { return "$line".Trim() }
  } catch { }
  return $null
}

Initialize-DshLang | Out-Null
