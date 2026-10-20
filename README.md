# Claude Desktop Custom Background

Show a background image, with the opacity of your choice, on **Claude Desktop**.

![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen)

> **Windows only for now.** The project relies on the Win32 API (windows, events, DWM) through PowerShell and .NET Framework, both shipped with Windows. There is no macOS or Linux equivalent yet.

![Comparison of several opacities](docs/opacity-comparison.png)

*Generated illustrations: a UI mockup with the sample image shipped in [`assets/`](assets/), not real screenshots. Only the `opacity` value changes from one panel to the next.*

## Table of contents

- [Why an overlay instead of CSS?](#why-an-overlay-instead-of-css)
- [Installation](#installation)
- [Configuration](#configuration)
- [Starting with Claude Desktop](#starting-with-claude-desktop)
- [How it works](#how-it-works)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Repository contents](#repository-contents)

## Why an overlay instead of CSS?

Claude Desktop is an Electron app, so injecting CSS may sound like the obvious route. It is not an option:

- the app is installed as an MSIX package in `C:\Program Files\WindowsApps\`, a read-only folder that updates itself, so it cannot be patched cleanly;
- the app **deliberately refuses to start** with a debugging port (`--remote-debugging-port`): `Claude: refusing to start — a debugging or network-override switch is present on the command line.`

So this project does not work around anything and never touches Claude. It draws **a separate, click-through window** on top of the Claude window.

## Installation

### Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (already included in Windows, nothing to install)
- Claude Desktop

Tested on Windows 11.

### Steps

1. **Get the project**: `git clone https://github.com/zomboky/claude-desktop-custom-background.git`, or download the ZIP from GitHub and extract it. Keep the folder somewhere stable: the automatic startup depends on its location.

2. **Pick your image**: put it anywhere you like (JPG, PNG, BMP, GIF or TIFF; WebP is not supported by .NET Framework). To try it out first, the sample [`assets/sample-background.jpg`](assets/sample-background.jpg) is used by default.

3. **Run the installer** in PowerShell, from the project folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   The script:
   - creates `config.json` from [`config.example.json`](config.example.json) if it does not exist;
   - creates a shortcut in your Startup folder (see [Starting with Claude Desktop](#starting-with-claude-desktop));
   - starts the overlay right away.

4. **Open Claude Desktop**: the image shows up. No administrator rights needed.

5. **Set your image**: edit `config.json` (see below). Changes are picked up within about a second, no restart needed.

For a one-off run, without installing the automatic startup:

```powershell
powershell -ExecutionPolicy Bypass -File .\overlay.ps1
```

(keep that PowerShell window open, or use `wscript.exe start-hidden.vbs` to run it without any window).

## Configuration

Everything is controlled by `config.json`, which is re-read live while the overlay runs. `config.json` is git-ignored, so your personal paths never get published.

```json
{
  "image": "C:/Users/you/Pictures/my-background.png",
  "opacity": 0.15,
  "fit": "cover"
}
```

| Key | Value | Purpose |
| --- | --- | --- |
| `image` | path | Image to display. Absolute, or relative to the folder containing `config.json`. |
| `opacity` | `0.01` to `0.99` (default `0.15`) | Opacity of the overlay. The higher it is, the more the image hides the interface. |
| `fit` | `"cover"` (default) or `"stretch"` | `cover` fills the window and crops without distortion; `stretch` stretches the image to the window size. |

> **Mind Windows paths in JSON.** Backslashes must be doubled (`C:\\Users\\you\\...`) or replaced by forward slashes (`C:/Users/you/...`). An invalid file is ignored: the previous image stays displayed.

The overlay is drawn **on top of** the interface (see [How it works](#how-it-works)), so keep the opacity low, between `0.05` and `0.2`, to keep text readable.

## Starting with Claude Desktop

`install.ps1` adds a `Claude overlay.lnk` shortcut to the Windows Startup folder (`shell:startup`). At every login:

1. `start-hidden.vbs` launches `overlay.ps1` with no visible window;
2. the overlay waits in the background, invisible, and shows nothing as long as Claude Desktop is not open;
3. as soon as a Claude window appears, the overlay covers it. When you minimize or close Claude, it hides;
4. an internal mutex prevents running two instances.

The net effect is that it behaves as if it started with Claude Desktop, without you having to think about it. Strictly speaking it starts with your session, not with Claude. The process stays running (about 140 MB of RAM); to stop it, right-click its notification-area icon and choose **Quit**.

To restart it manually:

```powershell
wscript.exe .\start-hidden.vbs
```

## How it works

![Layer diagram](docs/how-it-works.png)

Everything lives in [`overlay.ps1`](overlay.ps1): a small C# program compiled on the fly by PowerShell (`Add-Type`), with nothing to install.

- **A separate window.** The overlay is a borderless WinForms form using the extended styles `WS_EX_TRANSPARENT` (clicks go through), `WS_EX_NOACTIVATE` (it never takes focus) and `WS_EX_TOOLWINDOW` (no taskbar button, no Alt+Tab entry). The opacity is the window's own (`Form.Opacity`).
- **It finds Claude.** It enumerates top-level windows of class `Chrome_WidgetWin_1` owned by a `claude` process and keeps the largest one.
- **It follows Claude through events.** With `SetWinEventHook`, Windows notifies it on every move or resize of the window (`EVENT_OBJECT_LOCATIONCHANGE`), on foreground changes, on minimize/restore and on show/hide. There is no fast polling loop: a 250 ms timer is only a safety net (Claude opening, window order).
- **Exact dimensions.** It reads the visible frame with `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, which excludes the invisible margins of Windows 10/11, and declares itself per-monitor DPI v2 aware so it works in real pixels on scaled displays.
- **Z-order.** It sits **right above Claude** (`SetWindowPos` with the window that precedes Claude), rather than being "always on top": other windows stay in front, exactly as they would in front of Claude.
- **Fast image.** The image is decoded once, downscaled to the size of the largest screen and converted to `Format32bppPArgb` (the fastest format to draw). A copy cropped to the exact window size is cached: moving the window repaints nothing, resizing it only rebuilds that copy.
- **Rounded corners.** `DWMWA_WINDOW_CORNER_PREFERENCE` is set to rounded (Windows 11) to match the window.
- **Live config.** `config.json` is watched (modification time) and reloaded without a restart.

## Limitations

- **Windows only.** No macOS or Linux support for now.
- **The overlay is above the interface**, not behind it: Claude's backgrounds are opaque, so an overlay placed behind would be invisible. The image therefore sits on top of the text, hence the low opacity recommended.
- **Tracking is not perfectly synchronous**: a separate window follows Claude, so a slight lag is possible during very fast moves.
- The overlay follows **a single Claude window**: the largest visible one.
- This is not a Claude Desktop feature: a major app update that changes the type of its windows could require adapting the detection (`IsClaudeWindow` in `overlay.ps1`).
- Opacity is uniform over the whole image; there is no gradient.

## Troubleshooting

**The image does not show up.**
- Check that the overlay is running: `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'overlay.ps1' }`.
- Check that `config.json` is valid JSON (paths with `/` or `\\`) and that the image exists.
- To see its messages, run `overlay.ps1` in a visible PowerShell window: `config: opacity=… image=…` confirms the load, while `config: …` followed by an error tells you the cause.

**The overlay does not start at login.** Check that `Claude overlay.lnk` is in `shell:startup` and that the project folder has not been moved: run `install.ps1` again from the new location.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

The script stops the overlay and removes the startup shortcut. Since no Claude Desktop file was ever modified, there is nothing else to restore. You can then delete the project folder.

## Repository contents

| File | Purpose |
| --- | --- |
| `overlay.ps1` | The overlay (PowerShell + inline C#). |
| `start-hidden.vbs` | Runs `overlay.ps1` without a window. |
| `install.ps1` / `uninstall.ps1` | Add / remove the automatic startup. |
| `config.example.json` | Configuration template. |
| `assets/sample-background.jpg` | Sample image generated for this project. |
| `docs/` | README illustrations. |
