' Lance overlay.ps1 sans fenetre. Utilise par le raccourci du dossier Demarrage (voir install.ps1).
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\overlay.ps1""", 0, False
