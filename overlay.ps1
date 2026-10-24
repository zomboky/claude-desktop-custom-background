# Calque image semi-transparent collé à la fenêtre Claude Desktop.
# Ne touche pas à Claude : fenêtre séparée, transparente aux clics, placée juste au-dessus de Claude dans l'ordre Z.
# Suivi par événements Windows (SetWinEventHook) : la position suit Claude sans polling.
# Config (image, opacity, fit) relue en direct depuis config.json. Quitter : icône de la zone de notification > Quitter, ou Ctrl+C.
#   config.json (perso, ignoré par git) s'il existe, sinon config.example.json.
param([string]$Config = $(if (Test-Path (Join-Path $PSScriptRoot 'config.json')) { Join-Path $PSScriptRoot 'config.json' } else { Join-Path $PSScriptRoot 'config.example.json' }))

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Config $Config
    exit $LASTEXITCODE
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class ClaudeOverlay : Form
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);

    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
    const int EX_TRANSPARENT = 0x20, EX_TOOLWINDOW = 0x80, EX_LAYERED = 0x80000, EX_NOACTIVATE = 0x08000000;

    readonly string cfgPath;
    DateTime cfgTime = DateTime.MinValue;
    int lastCfgCheck;
    Bitmap src;   // image pré-réduite à la taille de l'écran, format PArgb (dessin rapide)
    Bitmap fit;   // src recadrée à la taille exacte de la fenêtre
    bool stretch;
    IntPtr claude = IntPtr.Zero;
    int lx, ly, lw, lh;
    bool shown;
    WinEventProc hookProc;
    readonly List<IntPtr> hooks = new List<IntPtr>();

    // Mis à jour par le watcher média (runspace PowerShell) : Claude lit une vidéo / un son.
    public static volatile bool MediaPlaying;
    bool hideOnMedia = true;
    bool manualHidden;   // bascule Ctrl+Alt+B ou menu de l'icône

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    const int WM_HOTKEY = 0x312;

    ClaudeOverlay(string cfgPath)
    {
        this.cfgPath = cfgPath;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        DoubleBuffered = true;
        Opacity = 0.15;
        int round = 2; // coins arrondis Win11 (ignoré ailleurs)
        HandleCreated += delegate
        {
            DwmSetWindowAttribute(Handle, 33, ref round, 4);
            // Ctrl+Alt+B : masquer / afficher (MOD_ALT|MOD_CONTROL|MOD_NOREPEAT)
            if (!RegisterHotKey(Handle, 1, 0x1 | 0x2 | 0x4000, (uint)Keys.B))
                Console.Error.WriteLine("raccourci Ctrl+Alt+B déjà utilisé par une autre application");
        };

        var tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "Claude overlay", Visible = true };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Masquer / afficher (Ctrl+Alt+B)", null, delegate { ToggleManual(); });
        menu.Items.Add("Quitter", null, delegate { tray.Visible = false; Application.Exit(); });
        tray.ContextMenuStrip = menu;

        // Événements : déplacement/redimensionnement de Claude, changement de premier plan, minimisation, show/hide.
        // SKIPOWNPROCESS : on ignore les événements causés par notre propre SetWindowPos.
        hookProc = OnWinEvent;
        foreach (var r in new uint[][] { new uint[] { 0x800B, 0x800B }, new uint[] { 3, 3 }, new uint[] { 0x16, 0x17 }, new uint[] { 0x8002, 0x8003 } })
            hooks.Add(SetWinEventHook(r[0], r[1], IntPtr.Zero, hookProc, 0, 0, 2));
        FormClosed += delegate { foreach (var h in hooks) UnhookWinEvent(h); };

        // Filet de sécurité (Claude lancé/fermé, ordre Z) ; le suivi de position passe par les événements.
        var timer = new Timer { Interval = 250 };
        timer.Tick += delegate { SafeTick(); };
        timer.Start();
    }

    void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time)
    {
        if (idObj != 0) return;                      // OBJID_WINDOW uniquement
        if (ev != 3 && hwnd != claude) return;       // sauf changement de premier plan, seule la fenêtre Claude nous intéresse
        SafeTick();
    }

    void SafeTick() { try { Tick(); } catch (Exception e) { Console.Error.WriteLine(e.Message); } }

    void ToggleManual() { manualHidden = !manualHidden; SafeTick(); }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == 1) ToggleManual();
        base.WndProc(ref m);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= EX_TRANSPARENT | EX_LAYERED | EX_TOOLWINDOW | EX_NOACTIVATE;
            return cp;
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e) { } // l'image couvre tout, pas de fond noir

    protected override void OnPaint(PaintEventArgs e)
    {
        if (src == null || ClientSize.Width < 1 || ClientSize.Height < 1) return;
        if (fit == null || fit.Width != ClientSize.Width || fit.Height != ClientSize.Height) BuildFit();
        e.Graphics.CompositingMode = CompositingMode.SourceCopy;
        e.Graphics.DrawImageUnscaled(fit, 0, 0);
    }

    void BuildFit()
    {
        int w = ClientSize.Width, h = ClientSize.Height;
        var nb = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(nb))
        {
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            if (stretch) g.DrawImage(src, new Rectangle(0, 0, w, h));
            else
            {
                float s = Math.Max((float)w / src.Width, (float)h / src.Height);
                float sw = w / s, sh = h / s;
                g.DrawImage(src, new Rectangle(0, 0, w, h), (src.Width - sw) / 2, (src.Height - sh) / 2, sw, sh, GraphicsUnit.Pixel);
            }
        }
        var old = fit; fit = nb;
        if (old != null) old.Dispose();
    }

    void LoadConfig()
    {
        var t = File.GetLastWriteTimeUtc(cfgPath);
        if (t == cfgTime) return;
        cfgTime = t;
        try
        {
            var cfg = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(cfgPath));
            double op = cfg.ContainsKey("opacity") ? Convert.ToDouble(cfg["opacity"]) : 0.15;
            Opacity = Math.Min(0.99, Math.Max(0.01, op));
            stretch = cfg.ContainsKey("fit") && "stretch".Equals(cfg["fit"] as string, StringComparison.OrdinalIgnoreCase);
            hideOnMedia = !cfg.ContainsKey("hideWhenMediaPlaying") || Convert.ToBoolean(cfg["hideWhenMediaPlaying"]);
            string p = cfg.ContainsKey("image") ? (string)cfg["image"] : "";
            p = Path.Combine(Path.GetDirectoryName(cfgPath), p);

            // Décode une fois, réduit à la taille du plus grand écran, convertit en PArgb.
            int maxW = 0, maxH = 0;
            foreach (var sc in Screen.AllScreens) { maxW = Math.Max(maxW, sc.Bounds.Width); maxH = Math.Max(maxH, sc.Bounds.Height); }
            Bitmap nb;
            using (var ms = new MemoryStream(File.ReadAllBytes(p)))
            using (var raw = Image.FromStream(ms))
            {
                double s = Math.Min(1.0, Math.Max((double)maxW / raw.Width, (double)maxH / raw.Height));
                int tw = Math.Max(1, (int)Math.Round(raw.Width * s)), th = Math.Max(1, (int)Math.Round(raw.Height * s));
                nb = new Bitmap(tw, th, PixelFormat.Format32bppPArgb);
                using (var g = Graphics.FromImage(nb))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(raw, 0, 0, tw, th);
                }
            }
            var oldSrc = src; src = nb;
            if (oldSrc != null) oldSrc.Dispose();
            if (fit != null) { fit.Dispose(); fit = null; }
            Invalidate();
            Console.WriteLine("config: opacity=" + Opacity + " fit=" + (stretch ? "stretch" : "cover") + " image=" + p + " (" + src.Width + "x" + src.Height + ")");
        }
        catch (Exception e) { Console.Error.WriteLine("config: " + e.Message); }
    }

    bool IsClaudeWindow(IntPtr h)
    {
        if (!IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero || GetWindowTextLength(h) == 0) return false;
        var cls = new StringBuilder(64);
        GetClassName(h, cls, 64);
        if (cls.ToString() != "Chrome_WidgetWin_1") return false;
        uint pid; GetWindowThreadProcessId(h, out pid);
        try { return Process.GetProcessById((int)pid).ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    bool FrameOf(IntPtr h, out RECT r) { return DwmGetWindowAttribute(h, 9, out r, 16) == 0; }

    IntPtr FindClaude()
    {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            RECT r;
            if (IsClaudeWindow(h) && FrameOf(h, out r))
            {
                long a = (long)(r.R - r.L) * (r.B - r.T);
                if (a > bestArea) { bestArea = a; best = h; }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    void HideOverlay() { if (shown) { ShowWindow(Handle, 0); shown = false; } }

    void Tick()
    {
        if (Environment.TickCount - lastCfgCheck > 1000) { lastCfgCheck = Environment.TickCount; LoadConfig(); }
        if (src == null) return;
        // Pas de calque au-dessus d'une vidéo en lecture dans Claude, ni quand l'utilisateur l'a masqué.
        if (manualHidden || (hideOnMedia && MediaPlaying)) { HideOverlay(); return; }
        if (claude == IntPtr.Zero || !IsWindow(claude) || !IsWindowVisible(claude)) claude = FindClaude();
        RECT r;
        if (claude == IntPtr.Zero || IsIconic(claude) || !FrameOf(claude, out r)) { HideOverlay(); return; }

        int x = r.L, y = r.T, w = r.R - r.L, h = r.B - r.T;
        if (w < 50 || h < 50) { HideOverlay(); return; }

        // Z-order : juste au-dessus de Claude (donc sous les fenêtres qui le recouvrent).
        IntPtr above = GetWindow(claude, 3); // GW_HWNDPREV
        uint flags = SWP_NOACTIVATE;
        if (above == Handle) flags |= SWP_NOZORDER;
        if (x == lx && y == ly && w == lw && h == lh && shown) flags |= SWP_NOMOVE | SWP_NOSIZE;
        if ((flags & SWP_NOZORDER) != 0 && (flags & SWP_NOMOVE) != 0) return;

        SetWindowPos(Handle, above, x, y, w, h, flags);
        lx = x; ly = y; lw = w; lh = h;
        if (!shown) { ShowWindow(Handle, 4); shown = true; } // SW_SHOWNOACTIVATE
    }

    public static void Run(string cfgPath)
    {
        bool first;
        var mutex = new System.Threading.Mutex(true, "Local\\ClaudeOverlaySingleton", out first);
        if (!first) return; // déjà lancé
        SetProcessDpiAwarenessContext(new IntPtr(-4)); // per-monitor v2 : coordonnées en vrais pixels
        Application.EnableVisualStyles();
        var f = new ClaudeOverlay(cfgPath);
        f.Show();
        ShowWindow(f.Handle, 0); // masqué tant que la fenêtre Claude n'est pas trouvée
        Application.Run();
        GC.KeepAlive(mutex);
    }
}
'@

# Watcher média : Claude déclare ses lectures audio/vidéo à Windows (System Media Transport Controls).
# Thread séparé qui interroge les sessions média et met à jour [ClaudeOverlay]::MediaPlaying.
$mediaWatcher = [powershell]::Create()
[void]$mediaWatcher.AddScript({
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
            Select-Object -First 1
        $task = $asTask.MakeGenericMethod([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]).Invoke($null, @([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()))
        $mgr = $task.GetAwaiter().GetResult()
    } catch { return }
    while ($true) {
        try {
            $playing = $false
            foreach ($s in $mgr.GetSessions()) {
                if ($s.SourceAppUserModelId -match 'claude' -and $s.GetPlaybackInfo().PlaybackStatus -eq 'Playing') { $playing = $true }
            }
            [ClaudeOverlay]::MediaPlaying = $playing
        } catch { }
        Start-Sleep -Milliseconds 300
    }
})
$null = $mediaWatcher.BeginInvoke()

Write-Host 'Calque actif. Masquer/afficher: Ctrl+Alt+B. Quitter: icône de notification > Quitter, ou Ctrl+C.'
[ClaudeOverlay]::Run($Config)
[Environment]::Exit(0)  # termine aussi le thread du watcher média
