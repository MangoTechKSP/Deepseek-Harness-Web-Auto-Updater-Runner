' ==========================================================================
'  dsh-boot-hidden.vbs -- run the DSH logon pre-flight with no window at all.
'
'  The DSH-Boot-AutoUpdate scheduled task launches this file through
'  wscript.exe. Window style 0 is what keeps it silent: the task itself would
'  still flash a console for a fraction of a second.
'
'  What happens after that:
'    tools\dsh-boot.ps1 -Mode launch
'      -> if port 3080 is already served:  does nothing
'      -> otherwise:                       runs run.bat hidden, which snapshots
'         the plugin set, checks the DSH update and rolls back by itself if the
'         new version does not verify, checks plugin compatibility, verifies the
'         whole plugin tree, and only then starts the server
'
'  Everything it prints goes to logs\boot.log, so a silent start is still an
'  inspectable one.
' ==========================================================================
Option Explicit
Dim fso, shell, toolDir, script, cmd
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

toolDir = fso.GetParentFolderName(WScript.ScriptFullName)
script  = toolDir & "\dsh-boot.ps1"

If Not fso.FileExists(script) Then
  ' Nothing to report to: write it where the user will actually look.
  Dim logDir, logFile, f
  logDir = fso.GetParentFolderName(toolDir) & "\logs"
  If Not fso.FolderExists(logDir) Then fso.CreateFolder logDir
  logFile = logDir & "\boot.log"
  Set f = fso.OpenTextFile(logFile, 8, True)
  f.WriteLine "[" & Now & "] boot: dsh-boot.ps1 is missing, logon check skipped"
  f.Close
  WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """ -Mode launch"
' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
WScript.Quit 0
