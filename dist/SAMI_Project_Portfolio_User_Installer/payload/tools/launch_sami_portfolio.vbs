Option Explicit
Dim shell, fso, toolRoot, appRoot, sourceBootstrap, localBase, cacheRoot, localTools, bootstrap, command, i
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
toolRoot = fso.GetParentFolderName(WScript.ScriptFullName)
appRoot = fso.GetParentFolderName(toolRoot)
sourceBootstrap = fso.BuildPath(toolRoot, "bootstrap_kanban.ps1")
localBase = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\SAMI-Kanban-WorkServer")
cacheRoot = fso.BuildPath(localBase, "launcher-cache")
localTools = fso.BuildPath(cacheRoot, "tools")
If Not fso.FolderExists(localBase) Then fso.CreateFolder(localBase)
If Not fso.FolderExists(cacheRoot) Then fso.CreateFolder(cacheRoot)
If Not fso.FolderExists(localTools) Then fso.CreateFolder(localTools)
bootstrap = fso.BuildPath(localTools, "bootstrap_kanban.ps1")
fso.CopyFile sourceBootstrap, bootstrap, True
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & bootstrap & """"
If Left(appRoot, 2) = "\\" Then command = command & " -TeamRoot """ & appRoot & """"
For i = 0 To WScript.Arguments.Count - 1
  command = command & " """ & WScript.Arguments(i) & """"
Next
shell.Run command, 0, False
