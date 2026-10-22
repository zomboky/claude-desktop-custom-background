#!/usr/bin/env bash
# Installe le lancement automatique du calque avec la session graphique (service systemd utilisateur), puis le démarre.
# Pas de sudo : seul ~/.config/systemd/user/claude-overlay.service est créé.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$unit_dir/claude-overlay.service"

if ! python3 - <<'EOF' 2>/dev/null
import gi
for ns, v in (("Gtk", "3.0"), ("GdkPixbuf", "2.0"), ("GtkLayerShell", "0.1")):
    gi.require_version(ns, v)
import cairo
EOF
then
    echo "Dépendances manquantes. Sur Arch / Omarchy :"
    echo "  sudo pacman -S --needed python-gobject python-cairo gtk3 gtk-layer-shell"
    exit 1
fi

if [ ! -f "$root/config.json" ]; then
    cp "$root/config.example.json" "$root/config.json"
    echo "config.json créé à partir de config.example.json : modifie-le pour choisir ton image."
fi
chmod +x "$here/overlay.py"

mkdir -p "$unit_dir"
cat > "$unit" <<EOF
[Unit]
Description=Fond d'écran pour Claude Desktop
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 "$here/overlay.py"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
systemctl --user daemon-reload
systemctl --user enable claude-overlay.service >/dev/null
echo "Lancement automatique installé : $unit"

if systemctl --user is-active --quiet graphical-session.target; then
    systemctl --user restart claude-overlay.service
    echo "Calque démarré (invisible tant que Claude Desktop n'est pas ouvert)."
else
    # Hyprland lancé sans uwsm : graphical-session.target n'est jamais atteint.
    echo "graphical-session.target inactif (Hyprland lancé sans uwsm ?)."
    echo "Ajoute plutôt cette ligne à ~/.config/hypr/hyprland.conf :"
    echo "  exec-once = /usr/bin/python3 \"$here/overlay.py\""
fi
