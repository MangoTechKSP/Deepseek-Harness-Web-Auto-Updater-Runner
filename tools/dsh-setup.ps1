#Requires -Version 5.1
<#
  dsh-setup.ps1 -- first-time install and repair.

  Called by install.bat, or from settings.bat. Everything is installed INTO
  THIS FOLDER, so the folder can live anywhere and can be moved later.

  What it does:
    1. checks node + npm
    2. creates <this folder>\dsh
    3. npm install @deepseek-ai/dsh@<channel>
    4. verifies that the installed tree boots (--version, --dump-config)
    5. registers the two scheduled tasks (logon check + 15 min backup)

  Exit codes: 0 ok, 1 fatal.
#>
[CmdletBinding()]
param(
  [string]$InstallDir = '',
  [string]$Profile = '',
  [string]$Tag = '',
  [switch]$SkipInstall,
  [switch]$SkipTasks
)

. "$PSScriptRoot\dsh-common.ps1"
$ErrorActionPreference = 'Stop'

$root = Get-DshRoot
$s = Get-DshSettings
if (-not $Profile) { $Profile = $s.profile }
if (-not $Tag) { $Tag = $s.tag }
if (-not $InstallDir) { $InstallDir = Get-DshInstallDir }

function Step([string]$n, [string]$text) { Write-Host ''; Write-Host (T-Line ("Step $n  " + $text)) -ForegroundColor Cyan }
function Fail([string]$text) { Write-Host ('ERROR: ' + (T $text)) -ForegroundColor Red; exit 1 }

Write-Host ("DSH Auto-Update - first-time setup") -ForegroundColor Cyan
Write-Host ("This folder will hold DSH and every plugin.")
Write-Host ("  " + $root)

# ---------------------------------------------------------------- 1/5
Step '1/5' 'Checking prerequisites'
$node = (Get-Command node -ErrorAction SilentlyContinue)
$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
if (-not $npm) { $npm = (Get-Command npm -ErrorAction SilentlyContinue) }
if (-not $node) { Fail 'ERROR: node was not found in PATH.' }
if (-not $npm) { Fail 'ERROR: npm was not found in PATH.' }
$nodeVer = (& node -v)
$npmVer = (& $npm.Source -v)
Write-Host ("  node : $nodeVer")
Write-Host ("  npm  : $npmVer")
$major = 0
if ($nodeVer -match '^v(\d+)') { $major = [int]$Matches[1] }
if ($major -lt 20) {
  Write-Host ("  " + (T 'Install Node.js 20 or newer from https://nodejs.org and run install.bat again.')) -ForegroundColor Yellow
  exit 1
}

# ---------------------------------------------------------------- 2/5
Step '2/5' 'Preparing the DSH install folder'
Write-Host ("  " + $InstallDir)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$pkg = Join-Path $InstallDir 'package.json'
if (-not (Test-Path -LiteralPath $pkg)) {
  $template = [ordered]@{ name = 'dsh-local-install'; private = $true; dependencies = [ordered]@{} }
  [System.IO.File]::WriteAllText($pkg, ($template | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("  created package.json")
} else {
  Write-Host ("  package.json already there")
}

# ---------------------------------------------------------------- 3/5
Step '3/5' 'Installing DSH'
$bin = Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
if ($SkipInstall) {
  Write-Host ("  -SkipInstall: leaving the files alone")
  if (-not (Test-Path -LiteralPath $bin)) {
    Write-Host ("  " + (T 'Nothing is installed here yet, so there is nothing to verify.'))
    exit 0
  }
} else {
  Write-Host ("  " + (T 'This download is about 250 MB. Please wait.'))
  Write-Host ("  npm install --save-exact @deepseek-ai/dsh@$Tag")
  Push-Location $InstallDir
  try { & $npm.Source install --save-exact "@deepseek-ai/dsh@$Tag" } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  " + (T 'Install failed. See the output above.')) -ForegroundColor Red
    exit 1
  }
}

# ---------------------------------------------------------------- 4/5
Step '4/5' 'Verifying the install'
$ok = $false
if (Test-Path -LiteralPath $bin) {
  $out = & node $bin --version 2>&1
  if ($LASTEXITCODE -eq 0) { $ok = $true; Write-Host ("  " + (T 'Already installed.') + " " + (@($out)[0])) }
}
if (-not $ok) {
  # A blocked npm build-script gate, a half-finished download or a stale cache
  # all look the same from here; the updater knows how to approve the scripts
  # and verify the tree, so hand the repair over to it before giving up.
  Write-Host ("  " + (T 'Verification failed: the installed DSH does not answer.')) -ForegroundColor Yellow
  Write-Host ("  retrying through the updater")
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'dsh-update.ps1') `
      -Tag $Tag -Profile $Profile -InstallDir $InstallDir -IgnorePluginCompat -SkipPluginUpdate
  if (Test-Path -LiteralPath $bin) {
    $out = & node $bin --version 2>&1
    if ($LASTEXITCODE -eq 0) { $ok = $true; Write-Host ("  " + (@($out)[0])) -ForegroundColor Green }
  }
}
if (-not $ok) { Fail 'Verification failed: the installed DSH does not answer.' }

$dump = & node $bin --profile $Profile --dump-config 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host ("  --dump-config exited " + $LASTEXITCODE) -ForegroundColor Yellow
} else {
  Write-Host ("  the plugin tree composes cleanly") -ForegroundColor Green
}

# ---------------------------------------------------------------- 5/5
Step '5/5' 'Registering the scheduled tasks'
if ($SkipTasks) {
  Write-Host ("  -SkipTasks: not touching the task scheduler")
} else {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'dsh-tasks.ps1')
}

Write-Host ''
Write-Host ("Done. Next: double-click run.bat to start DSH.") -ForegroundColor Green
Write-Host ("The first start also checks for updates and can install them for you.")
Write-Host ("  http://127.0.0.1:$($s.port)")
exit 0
