Set WshShell = CreateObject("WScript.Shell")
Set FSO = CreateObject("Scripting.FileSystemObject")
scriptPath = FSO.GetParentFolderName(WScript.ScriptFullName)
batPath = scriptPath & "\run_kanban.bat"
WshShell.Run Chr(34) & batPath & Chr(34), 0, False
