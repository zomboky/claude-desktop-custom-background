#!/usr/bin/env python3
# Calque image semi-transparent collé à la fenêtre Claude Desktop, version Linux (Hyprland, donc Omarchy).
# Ne touche pas à Claude : surface layer-shell séparée, transparente aux clics, posée exactement sur la fenêtre Claude.
# Suivi par les événements Hyprland (socket2) : la position suit Claude sans polling rapide.
# Config (image, opacity, fit, match) relue en direct depuis config.json. Quitter : Ctrl+C, ou systemctl --user stop claude-overlay.
#   config.json (perso, ignoré par git) à la racine du projet s'il existe, sinon config.example.json.
import argparse
import fcntl
import json
import math
import os
import re
import signal
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# app_id Wayland ou classe X11 de Claude Desktop selon le paquet (claude-desktop-bin, claude-desktop-debian, ...).
DEFAULT_MATCH = r"(?i)^(claude|claude-desktop|com\.anthropic\.claude.*)$"
NAMESPACE = "claude-overlay"


# --- Hyprland IPC -------------------------------------------------------------------------------

def hypr_dir():
    """Dossier des sockets de l'instance Hyprland courante, ou None si Hyprland ne tourne pas."""
    run = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    base = os.path.join(run, "hypr")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if sig and os.path.exists(os.path.join(base, sig, ".socket.sock")):
        return os.path.join(base, sig)
    # Signature absente (lancé hors session) ou périmée (Hyprland redémarré) : instance la plus récente.
    try:
        dirs = [os.path.join(base, d) for d in os.listdir(base)]
    except OSError:
        return None
    dirs = [d for d in dirs if os.path.exists(os.path.join(d, ".socket.sock"))]
    return max(dirs, key=os.path.getmtime, default=None)


def hyprctl(path, cmd):
    """Équivalent de `hyprctl -j <cmd>` via le socket, sans lancer de processus."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        s.connect(os.path.join(path, ".socket.sock"))
        s.sendall(("j/" + cmd).encode())
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
    return json.loads(b"".join(chunks))


def option_int(path, name):
    try:
        return int(hyprctl(path, "getoption " + name).get("int", 0))
    except Exception:
        return 0


# --- Choix de la fenêtre (fonctions pures, testables sans Hyprland) -----------------------------

def alive(c):
    return c.get("mapped", True) and not c.get("hidden")


def is_claude(c, pattern):
    return bool(pattern.search(c.get("class") or "") or pattern.search(c.get("initialClass") or ""))


def on_screen(c, m):
    """La fenêtre est-elle sur l'espace de travail affiché de son écran ?"""
    ws = c["workspace"]["id"]
    special = (m.get("specialWorkspace") or {}).get("id", 0)
    if special:
        return ws == special  # espace spécial ouvert : il recouvre l'espace normal
    return ws == m["activeWorkspace"]["id"] or bool(c.get("pinned"))


def find_claude(clients, monitors, pattern):
    """Plus grande fenêtre Claude visible -> (client, monitor), ou None."""
    mons = {m["id"]: m for m in monitors}
    best, best_area = None, 0
    for c in clients:
        m = mons.get(c.get("monitor"))
        if not alive(c) or not is_claude(c, pattern) or m is None or not on_screen(c, m):
            continue
        a = c["size"][0] * c["size"][1]
        if a > best_area:
            best, best_area = c, a
    if best is None:
        return None
    # Une autre fenêtre plein écran ou maximisée sur le même espace de travail cache Claude.
    if not best.get("fullscreen"):
        for o in clients:
            if o is not best and alive(o) and o.get("fullscreen") and o["workspace"]["id"] == best["workspace"]["id"]:
                return None
    return best, mons[best["monitor"]]


def holes(target, clients, border):
    """Rectangles (coordonnées locales) des fenêtres flottantes posées sur Claude : le calque n'y dessine rien."""
    if target.get("fullscreen"):
        return []
    tx, ty = target["at"]
    tw, th = target["size"]
    out = []
    for c in clients:
        if c is target or not c.get("floating") or not alive(c):
            continue
        if c["workspace"]["id"] != target["workspace"]["id"] and not (c.get("pinned") and c.get("monitor") == target.get("monitor")):
            continue
        # Claude flottant : seules les fenêtres activées plus récemment que lui sont au-dessus.
        if target.get("floating") and c.get("focusHistoryID", 0) > target.get("focusHistoryID", 0):
            continue
        x, y = c["at"]
        w, h = c["size"]
        x0, y0 = max(x - border, tx), max(y - border, ty)
        x1, y1 = min(x + w + border, tx + tw), min(y + h + border, ty + th)
        if x1 > x0 and y1 > y0:
            out.append((x0 - tx, y0 - ty, x1 - x0, y1 - y0))
    return out


# --- Calque -------------------------------------------------------------------------------------

def load_gtk():
    os.environ.setdefault("GDK_BACKEND", "wayland")
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        gi.require_version("Gdk", "3.0")
        gi.require_version("GdkPixbuf", "2.0")
        gi.require_version("GtkLayerShell", "0.1")
        gi.require_foreign("cairo")
        from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, GtkLayerShell
        import cairo
    except (ImportError, ValueError) as e:
        sys.exit("dépendances manquantes (%s) : sudo pacman -S --needed python-gobject python-cairo gtk3 gtk-layer-shell" % e)
    return Gdk, GdkPixbuf, GLib, Gtk, GtkLayerShell, cairo


def run(cfg_path):
    Gdk, GdkPixbuf, GLib, Gtk, GtkLayerShell, cairo = load_gtk()
    if not GtkLayerShell.is_supported():
        sys.exit("le compositeur ne gère pas wlr-layer-shell (session Wayland Hyprland requise)")
    Edge, Layer = GtkLayerShell.Edge, GtkLayerShell.Layer

    class ClaudeOverlay(Gtk.Window):
        def __init__(self):
            super().__init__()
            self.cfg_path = cfg_path
            self.cfg_time = None
            self.last_cfg_check = 0
            self.opacity = 0.15
            self.stretch = False
            self.pattern = re.compile(DEFAULT_MATCH)
            self.src = None      # image pré-réduite à la taille du plus grand écran
            self.fit = None      # src recadrée à la taille exacte de la fenêtre (surface cairo)
            self.fit_key = None
            self.place = None    # (écran, x, y, w, h, plein écran) appliqué, None = masqué
            self.cut = []        # fenêtres flottantes au-dessus de Claude
            self.rounding = self.border = 0
            self.hypr = None
            self.events = None
            self.events_watch = None
            self.pending = False

            GtkLayerShell.init_for_window(self)
            GtkLayerShell.set_namespace(self, NAMESPACE)
            GtkLayerShell.set_layer(self, Layer.TOP)
            GtkLayerShell.set_exclusive_zone(self, -1)  # ignore les zones réservées (waybar) : marges = coordonnées écran
            GtkLayerShell.set_anchor(self, Edge.TOP, True)
            GtkLayerShell.set_anchor(self, Edge.LEFT, True)
            self.set_app_paintable(True)
            visual = self.get_screen().get_rgba_visual()
            if visual is not None:
                self.set_visual(visual)
            self.set_size_request(1, 1)
            self.input_shape_combine_region(cairo.Region())  # région d'entrée vide : les clics traversent
            self.connect("draw", self.on_draw)

            # Filet de sécurité (Claude lancé/fermé, redimensionnement à la souris qui n'émet aucun événement).
            GLib.timeout_add(250, self.on_timer)

        # Surface montée une seule fois puis jamais démontée : « masqué » = rien dessiné, pas d'animation d'ouverture.
        def on_draw(self, _w, cr):
            cr.set_operator(cairo.OPERATOR_SOURCE)
            cr.set_source_rgba(0, 0, 0, 0)
            cr.paint()
            if self.place is None or self.src is None:
                return True
            w, h, sc = self.get_allocated_width(), self.get_allocated_height(), self.get_scale_factor()
            if self.fit_key != (w, h, sc):
                self.build_fit(w, h, sc)
            r = min(self.rounding, w / 2, h / 2)
            if r > 0:
                cr.new_sub_path()
                cr.arc(w - r, r, r, -math.pi / 2, 0)
                cr.arc(w - r, h - r, r, 0, math.pi / 2)
                cr.arc(r, h - r, r, math.pi / 2, math.pi)
                cr.arc(r, r, r, math.pi, 3 * math.pi / 2)
                cr.close_path()
                cr.clip()
            cr.set_operator(cairo.OPERATOR_OVER)
            cr.set_source_surface(self.fit, 0, 0)
            cr.paint_with_alpha(self.opacity)
            if self.cut:
                cr.reset_clip()
                cr.set_operator(cairo.OPERATOR_CLEAR)
                for x, y, cw, ch in self.cut:
                    cr.rectangle(x, y, cw, ch)
                cr.fill()
            return True

        def build_fit(self, w, h, sc):
            pw, ph = max(1, w * sc), max(1, h * sc)
            src = self.src
            sw, sh = src.get_width(), src.get_height()
            if not self.stretch:
                s = max(pw / sw, ph / sh)
                cw, ch = min(sw, max(1, round(pw / s))), min(sh, max(1, round(ph / s)))
                src = src.new_subpixbuf((sw - cw) // 2, (sh - ch) // 2, cw, ch)
            pb = src.scale_simple(pw, ph, GdkPixbuf.InterpType.BILINEAR)
            self.fit = Gdk.cairo_surface_create_from_pixbuf(pb, sc, None)
            self.fit_key = (w, h, sc)

        def load_config(self):
            try:
                t = os.stat(self.cfg_path).st_mtime_ns
            except OSError as e:
                if self.cfg_time != -1:
                    print("config: %s" % e, file=sys.stderr)
                self.cfg_time = -1
                return
            if t == self.cfg_time:
                return
            self.cfg_time = t
            try:
                with open(self.cfg_path, encoding="utf-8-sig") as f:
                    cfg = json.load(f)
                opacity = min(0.99, max(0.01, float(cfg.get("opacity", 0.15))))
                stretch = str(cfg.get("fit", "cover")).lower() == "stretch"
                pattern = re.compile(cfg.get("match") or DEFAULT_MATCH)
                p = os.path.join(os.path.dirname(os.path.abspath(self.cfg_path)), os.path.expanduser(cfg.get("image", "")))

                # Décode une fois, réduit à la taille (en pixels réels) du plus grand écran.
                pb = GdkPixbuf.Pixbuf.new_from_file(p).apply_embedded_orientation()
                disp = Gdk.Display.get_default()
                max_w = max_h = 1
                for i in range(disp.get_n_monitors()):
                    mon = disp.get_monitor(i)
                    g, sc = mon.get_geometry(), mon.get_scale_factor()
                    max_w, max_h = max(max_w, g.width * sc), max(max_h, g.height * sc)
                s = min(1.0, max(max_w / pb.get_width(), max_h / pb.get_height()))
                if s < 1:
                    pb = pb.scale_simple(max(1, round(pb.get_width() * s)), max(1, round(pb.get_height() * s)), GdkPixbuf.InterpType.HYPER)

                self.opacity, self.stretch, self.pattern, self.src = opacity, stretch, pattern, pb
                self.fit = self.fit_key = None
                self.queue_draw()
                print("config: opacity=%s fit=%s image=%s (%dx%d)" % (opacity, "stretch" if stretch else "cover", p, pb.get_width(), pb.get_height()), flush=True)
            except Exception as e:
                print("config: %s" % e, file=sys.stderr, flush=True)

        def gdk_monitor(self, m):
            disp = Gdk.Display.get_default()
            for i in range(disp.get_n_monitors()):
                mon = disp.get_monitor(i)
                g = mon.get_geometry()
                if (g.x, g.y) == (m["x"], m["y"]):
                    return mon
            return None

        # Événements Hyprland : déplacement, ouverture/fermeture, changement d'espace de travail, plein écran, flottant...
        def connect_events(self):
            self.disconnect_events()
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(os.path.join(self.hypr, ".socket2.sock"))
            s.setblocking(False)
            self.events = s
            self.events_watch = GLib.io_add_watch(s.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.on_events)

        def disconnect_events(self):
            if self.events_watch is not None:
                GLib.source_remove(self.events_watch)
                self.events_watch = None
            if self.events is not None:
                self.events.close()
                self.events = None

        def on_events(self, _fd, _cond):
            if self.events is None:
                return False
            try:
                data = self.events.recv(65536)
            except BlockingIOError:
                return True
            except OSError:
                data = b""
            if not data:  # Hyprland arrêté ou redémarré : reconnexion au prochain tick
                self.events_watch = None  # retiré par GLib puisqu'on renvoie False
                self.disconnect_events()
                self.hypr = None
                return False
            if not self.pending:
                self.pending = True
                GLib.timeout_add(10, self.on_event_burst)  # regroupe les rafales d'événements
            return True

        def on_event_burst(self):
            self.pending = False
            self.safe_tick()
            return False

        def on_timer(self):
            self.safe_tick()
            return True

        def safe_tick(self):
            try:
                self.tick()
            except OSError as e:  # socket Hyprland disparu
                print(e, file=sys.stderr, flush=True)
                self.disconnect_events()
                self.hypr = None
                self.hide_overlay()
            except Exception as e:
                print(e, file=sys.stderr, flush=True)

        def hide_overlay(self):
            if self.place is not None:
                self.place = None
                self.cut = []
                GtkLayerShell.set_margin(self, Edge.TOP, 0)
                GtkLayerShell.set_margin(self, Edge.LEFT, 0)
                self.set_size_request(1, 1)
                self.resize(1, 1)
                self.queue_draw()

        def tick(self):
            now = GLib.get_monotonic_time()
            refresh_cfg = now - self.last_cfg_check > 1000000
            if refresh_cfg:
                self.last_cfg_check = now
                self.load_config()
            if self.src is None:
                return self.hide_overlay()
            path = hypr_dir()
            if path is None:
                return self.hide_overlay()
            if path != self.hypr or self.events is None:
                self.hypr = path
                self.connect_events()
                refresh_cfg = True
            if refresh_cfg:
                self.rounding = option_int(path, "decoration:rounding")
                self.border = option_int(path, "general:border_size")

            clients = hyprctl(path, "clients")
            found = find_claude(clients, hyprctl(path, "monitors"), self.pattern)
            if found is None:
                return self.hide_overlay()
            c, m = found
            (x, y), (w, h) = c["at"], c["size"]
            if w < 50 or h < 50:
                return self.hide_overlay()

            full = c.get("fullscreen") in (True, 2)
            place = (m["name"], x - m["x"], y - m["y"], w, h, full)
            if place != self.place:
                if self.place is None or self.place[0] != place[0]:
                    GtkLayerShell.set_monitor(self, self.gdk_monitor(m))
                if self.place is None or self.place[5] != full:
                    # Plein écran : la couche « top » passe sous la fenêtre, on monte d'un cran.
                    GtkLayerShell.set_layer(self, Layer.OVERLAY if full else Layer.TOP)
                GtkLayerShell.set_margin(self, Edge.LEFT, place[1])
                GtkLayerShell.set_margin(self, Edge.TOP, place[2])
                self.set_size_request(w, h)
                self.resize(w, h)
                self.place = place
                self.queue_draw()
            cut = holes(c, clients, self.border)
            if cut != self.cut:
                self.cut = cut
                self.queue_draw()

    f = ClaudeOverlay()
    f.show_all()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, Gtk.main_quit)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit)
    f.safe_tick()
    Gtk.main()


def list_windows(cfg_path):
    """Aide au réglage de "match" : liste les fenêtres connues de Hyprland."""
    try:
        with open(cfg_path, encoding="utf-8-sig") as f:
            pattern = re.compile(json.load(f).get("match") or DEFAULT_MATCH)
    except Exception:
        pattern = re.compile(DEFAULT_MATCH)
    path = hypr_dir()
    if path is None:
        sys.exit("Hyprland introuvable (pas de socket dans $XDG_RUNTIME_DIR/hypr)")
    for c in hyprctl(path, "clients"):
        print("%s class=%-24s initialClass=%-24s %s" % ("*" if is_claude(c, pattern) else " ", c.get("class"), c.get("initialClass"), c.get("title")))
    print("\n* = reconnue comme fenêtre Claude (regex : %s)" % pattern.pattern)


def main():
    default = ROOT / "config.json"
    if not default.exists():
        default = ROOT / "config.example.json"
    ap = argparse.ArgumentParser(description="Image de fond pour Claude Desktop sous Hyprland.")
    ap.add_argument("--config", default=str(default), help="fichier de configuration (défaut : %(default)s)")
    ap.add_argument("--list-windows", action="store_true", help="liste les fenêtres et indique celles reconnues comme Claude")
    args = ap.parse_args()
    if args.list_windows:
        return list_windows(args.config)

    lock = open(os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "claude-overlay.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return print("déjà lancé")
    print("Calque actif. Quitter : Ctrl+C ou systemctl --user stop claude-overlay.", flush=True)
    run(args.config)


if __name__ == "__main__":
    main()
