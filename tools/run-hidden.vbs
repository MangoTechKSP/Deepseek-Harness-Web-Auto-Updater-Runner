' ===========================================================================
'  run-hidden.vbs -- run a PowerShell script with NO window, ever.
'
'  Usage (Task Scheduler action):
'    wscript.exe  "...\tools\run-hidden.vbs"  dsh-plugin-backup.ps1  -Mode auto
'
'  Why this exists
'    Task Scheduler running powershell.exe directly creates a console for it.
'    On Windows 11 the default terminal application is Windows Terminal, so that
'    console is handed off to a BRAND NEW Terminal window - which flashes on the
'    desktop for the ~1 second the script takes, then vanishes. That is exactly
'    the "a PowerShell window keeps flashing up" symptom.
'
'    wscript.exe is a GUI-subsystem program: it never allocates a console of its
'    own. It then starts PowerShell with window style 0 (SW_HIDE), so nothing is
'    ever drawn on screen.
'
'  Arguments
'    arg 0      : the .ps1 to run. A bare file name is resolved next to this
'                 script; a full path is used as given.
'    arg 1..n   : passed through to the script, unchanged.
' ===========================================================================
Option Explicit

Dim shell, toolDir, target, i, cmd
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count = 0 Then
  WScript.Quit 2
End If

' The directory this script lives in (InStrRev keeps the trailing backslash).
toolDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))

target = WScript.Arguments(0)
If InStr(target, "\") = 0 And InStr(target, ":") = 0 Then
  target = toolDir & target
End If

' A hidden run that cannot find its script would otherwise fail completely
' silently; quit 3 so Task Scheduler's LastResult shows something is wrong.
Dim fso
Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FileExists(target) Then
  WScript.Quit 3
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """"
For i = 1 To WScript.Arguments.Count - 1
  cmd = cmd & " " & WScript.Arguments(i)
Next

' 0 = hidden window, False = do not wait for PowerShell to finish.
shell.Run cmd, 0, False
