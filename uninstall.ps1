# Arrête le calque et retire le lancement automatique. Les fichiers du dossier ne sont pas supprimés.
$lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude overlay.lnk'
if (Test-Path $lnkPath) { Remove-Item $lnkPath; Write-Host "Raccourci supprimé : $lnkPath" }
else { Write-Host 'Aucun raccourci de démarrage trouvé.' }

$overlay = Join-Path $PSScriptRoot 'overlay.ps1'
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($overlay) }
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force; Write-Host "Calque arrêté (PID $($p.ProcessId))." }
if (-not $procs) { Write-Host 'Aucun calque en cours d''exécution.' }
