' ask-update.vbs -- the "an update is available" question.
'
' Every string arrives as an argument, so this file holds no language of its
' own and never needs translating:
'   wscript.exe ask-update.vbs "<title>" <line> [<line>...] <timeoutSeconds>
'
' Exit codes (read by tools\dsh-boot.ps1):
'   6 = the user said yes        7 = no, timed out, or anything unexpected
Option Explicit
Dim a, title, body, sec, r, sh, i
Set a = WScript.Arguments
If a.Count < 2 Then WScript.Quit 7
title = a(0)
If Not IsNumeric(a(a.Count - 1)) Then WScript.Quit 7
sec = CLng(a(a.Count - 1))
If sec < 1 Then sec = 1
body = ""
For i = 1 To a.Count - 2
  If Len(body) > 0 Then body = body & vbCrLf & vbCrLf
  body = body & a(i)
Next
Set sh = CreateObject("WScript.Shell")
' 4 + 48 + 4096 = Yes/No buttons, exclamation icon, always on top
r = sh.Popup(body, sec, title, 4 + 48 + 4096)
If r = 6 Then WScript.Quit 6
WScript.Quit 7