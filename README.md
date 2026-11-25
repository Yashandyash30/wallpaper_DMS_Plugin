# Wallpaper Span

A DankMaterialShell (DMS) composite plugin that adds a multi-monitor wallpaper browser with automatic wide-wallpaper spanning, same-on-all mode, and per-display selection.

Works on Niri, Hyprland, and other Wayland compositors supported by DMS while preserving DMS wallpaper transitions and Matugen theme generation.

## Features

- **Physical-space alignment ([Spanright](https://github.com/andresjmorales/spanright) method)**: Uses monitor physical dimensions from EDID (`physical_size` on Niri / `physicalPixelDensity`), physical bezel gap (`mm`), and per-display vertical offset so objects stay the same real-world size across mixed-DPI screens and cross bezels smoothly.
- **Per-display vertical & bezel tuning**: Use **Align** in the panel to nudge any screen vertically (`↓10`, `↓2`, `↑2`, `↑10`) and tune bezel gap (`mm`). Changes preview in the monitor diagram and re-crop live.
- **Per-display or unified mode**:
  - **All Displays**: Automatically spans wide images (`>= 2.2:1` by default) and applies standard images across all monitors.
  - **Single Display**: Target any individual monitor from the top strip or assign straight from any wallpaper card (`1`, `2`, ...).
  - **Quick overrides**: Force **Span** or **Same** on any image from its card buttons.
- **Filters & search**: Filter by `All`, `Wide`, or `Normal`, search by filename, and browse any folder with recursive scanning.
- **Optional background watcher**: Enable **Auto-Split External Wallpaper Changes** in plugin settings to auto-span wide wallpapers picked from DMS Dash or Settings.
- **Cached slices**: Split PNGs are cached under `~/.cache/dms/wallpaperSpan` by file path, mtime, size, and monitor layout so switching back is instant.
- **IPC support**: Control spanning from keybinds or scripts via `dms ipc call wallpaperSpan ...`.

## Requirements

- DankMaterialShell (DMS / `dux-shell`) `>= 1.7.0`
- `imagemagick` (`magick` or `convert`/`identify`)

Install ImageMagick on Arch / CachyOS:

```bash
sudo pacman -S imagemagick
```

## Installation

Clone directly into your DMS plugins directory (or symlink your local checkout):

```bash
git clone https://github.com/Yashandyash30/wallpaper_DMS_Plugin.git ~/.config/dms/plugins/wallpaperSpan
```

Or with a symlink:

```bash
ln -s /path/to/wallpaper_DMS_Plugin ~/.config/dms/plugins/wallpaperSpan
```

Then in DMS:

1. Open **Settings → Plugins**, find **Wallpaper Span**, and enable it.
2. Add **Wallpaper Span** to your DankBar (or open it from Control Center).

## IPC Commands

```bash
dms ipc call wallpaperSpan apply /path/to/image.png
dms ipc call wallpaperSpan span /path/to/wide.png
dms ipc call wallpaperSpan same /path/to/normal.png
dms ipc call wallpaperSpan setMonitor DP-1 /path/to/image.png
dms ipc call wallpaperSpan clearCache
```

## Development & Testing

Run the test suite locally:

```bash
./tests/test_span.sh
```

## License

MIT — see [LICENSE](LICENSE).
