Option Explicit
Dim shell, fso, toolRoot, bootstrap, command, i
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
toolRoot = fso.GetParentFolderName(WScript.ScriptFullName)
bootstrap = fso.BuildPath(toolRoot, "bootstrap_kanban.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & bootstrap & """"
For i = 0 To WScript.Arguments.Count - 1
  command = command & " """ & WScript.Arguments(i) & """"
Next
shell.Run command, 0, False
