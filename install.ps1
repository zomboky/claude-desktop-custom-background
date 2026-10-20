# Installe le lancement automatique du calque à l'ouverture de session Windows, puis le démarre.
# Crée un raccourci dans le dossier Démarrage (pas de droits admin, rien d'autre n'est modifié).
$ErrorActionPreference = 'Stop'

$vbs = Join-Path $PSScriptRoot 'start-hidden.vbs'
$cfg = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $cfg)) {
    Copy-Item (Join-Path $PSScriptRoot 'config.example.json') $cfg
    Write-Host "config.json créé à partir de config.example.json : modifie-le pour choisir ton image."
}

$lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude overlay.lnk'
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + $vbs + '"'
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description = 'Fond d''écran pour Claude Desktop'
$lnk.Save()
Write-Host "Lancement automatique installé : $lnkPath"

Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
Write-Host 'Calque démarré (invisible tant que Claude Desktop n''est pas ouvert).'
