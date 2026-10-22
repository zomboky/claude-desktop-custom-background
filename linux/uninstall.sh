#!/usr/bin/env bash
# Arrête le calque et retire le lancement automatique. Les fichiers du dossier ne sont pas supprimés.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/claude-overlay.service"

if [ -f "$unit" ]; then
    systemctl --user disable --now claude-overlay.service 2>/dev/null
    rm -f "$unit"
    systemctl --user daemon-reload
    echo "Service supprimé : $unit"
else
    echo "Aucun service de démarrage trouvé."
fi

if pkill -f "$here/overlay.py"; then
    echo "Calque arrêté."
else
    echo "Aucun calque en cours d'exécution."
fi
