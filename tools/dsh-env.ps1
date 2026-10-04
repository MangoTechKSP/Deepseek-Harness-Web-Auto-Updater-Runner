# dsh-env.ps1 -- print the saved settings as BAT "set" lines.
#
# The .bat entry points read this once with
#     for /f "usebackq delims=" %%i in (`powershell -File tools\dsh-env.ps1`) do set "%%i"
# so the batch files themselves stay free of any language or configuration text.
[CmdletBinding()]
param()
. "$PSScriptRoot\dsh-common.ps1"
$s = Get-DshSettings
function Flag($v) { if ($v -eq $true -or "$v" -eq 'True' -or "$v" -eq '1') { '1' } else { '0' } }
"DSH_ROOT=$(Get-DshRoot)"
"DSH_PORT=$($s.port)"
"DSH_PROFILE=$($s.profile)"
"DSH_TAG=$($s.tag)"
"DSH_OPEN_BROWSER=$(Flag $s.openBrowser)"
"DSH_PROMPT_UPDATE=$(Flag $s.promptUpdate)"
"DSH_BACKUP_KEEP=$($s.backupKeep)"
# Resolve "auto" here, once, and export the answer: the .bat files then pass the
# same language to the PowerShell scripts AND to the Node scripts, which would
# otherwise ask Windows and V8 separately and could disagree.
Initialize-DshLang | Out-Null
"DSH_LANG=$(Get-DshLangName)"
