Option Explicit
Dim shell, fso, root, launcher
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = fso.BuildPath(fso.BuildPath(root, "tools"), "launch_sami_portfolio.vbs")
shell.Run "wscript.exe """ & launcher & """", 0, False
