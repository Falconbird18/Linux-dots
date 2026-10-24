# Tempora Desktop
This is my in-progress hyprland settup. This includes an ags bar, a spotify theme using spicetify, and a starship config. This setup is still in development, and while in a usable state, is not perfect. Expect bugs!
- The name comes from the latin word "tempora", meaning "seasons" or "times."
## Features
- Custom icon theme based on [Microsoft Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)
- Unique control panel
- AI assistant using either locally run models or google gemini
- 4 beautiful themes with light and dark mode
- (Mostly) Complete spotify theme
- Wallpaper switching
- Various useful tools such as screenshots, screensnips, and a color picker.

This is the state as of December 9th, 2024
  ![Current setup](https://github.com/user-attachments/assets/a0af4e89-e018-42b2-90ee-df8c8e606b5d)

  
## Dependencies
Before you install, check that you have the following dependencies installed (and probably more that I forgot about):
- `hyprland` - Wayland compositor
- `ags` - Widgets (top bar, etc.)
- `wofi` - App launcher
- `starship` - Terminal config
- `fish` - Shell
- `spicetify` - Spotify customization
- `monaspace` - Github Monaspace fonts
- `hyprlock` - Hyprland Lock screen
- `sddm` - Simple Desktop Display Manager (Login screen)
- `brightnessctl` - A CLI for controling screen brightness
- `cliphist` - Wayland clipboard manager
- `webkit` - Specifically `webkit2gtk-4.1` for arch
## Installation

Run from this checkout as your normal user (from any working directory):

```bash
./install.sh --dry-run    # preview file changes
./install.sh              # install configs, launchers, and desktop entries
./install.sh --keyd       # also install/enable the bundled keyd keyboard layout
./install.sh --musescore-reverb # also install Dragonfly VST3 reverbs on Arch
```

Display setup prompts you to choose automatic settings (the default) or the
bundled laptop settings. For unattended installs, select explicitly:

```bash
./install.sh --display=auto          # preferred resolution, automatic layout and scaling
./install.sh --display=preconfigured # bundled 2880x1920@120, 200%, HDR laptop profile
./install.sh --dry-run --display=auto
```

Without a terminal, automatic settings are selected by default. Automatic setup
writes `hypr/dms/outputs.lua` in your installed config, leaving the checkout's
profile intact. Hyprland chooses each display's preferred mode and scale when
it connects, including on first login; no running Hyprland session is needed.
HDR, 10-bit color, and VRR are not forced. You can adjust the result in DMS's
display settings, including scaling and physical monitor arrangement. Existing
display settings are backed up before replacement. Automatic scaling depends
on the display's reported physical size, so manual adjustment may still be needed.

The installer uses this checkout, including local edits; it does not download an
older copy of the dots or run third-party installers.

Every entry in `.config` is installed, including hidden files and newly added
folders. Existing directories are merged, and unrelated files are kept. Each
replaced file or symlink is moved to a unique backup directory under
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/backups` with its relative path retained.
The backup location is printed when installation finishes. To restore an entry,
copy it from that directory to its original destination.

The installer also copies `.local/bin` launchers and `.local/share/applications`
desktop entries. It does not install fonts, icons, wallpapers, or Spicetify
assets. It respects `XDG_CONFIG_HOME` and `XDG_DATA_HOME`; repeat runs skip
identical files. The current configs cover Hyprland/DMS, Kitty, Fish, Starship,
Electron/Chromium app flags, session environment, and MuseScore audio settings.

Dependencies and DMS must be installed separately. System settings are only
changed with `--keyd`; the previous keyboard layout is backed up in
`/etc/keyd/dotfiles-backup-*`. Optional reverb packages are installed only with
`--musescore-reverb`.

The desktop-entry database refresh has a 10 second timeout. The installer does
not reload Hyprland automatically: run `hyprctl reload` when ready, and restart
affected apps. Log in again for session environment changes to take effect.

### MuseScore at 200% scaling

The bundled app-menu entry uses the `~/.local/bin/mscore` wrapper. Ensure
`~/.local/bin` is in `PATH`. For the distro build, the wrapper selects native
Wayland using `MU_QT_QPA_PLATFORM=wayland` for sharp HiDPI rendering (requires
`qt6-wayland` on Arch). MuseScore uses its own platform override rather than
only `QT_QPA_PLATFORM`.

For the official VST-enabled build, the wrapper instead defaults to `xcb`
(XWayland), setting both `MU_QT_QPA_PLATFORM` and `QT_QPA_PLATFORM` so a
session-wide Wayland preference cannot override the choice. Dragonfly's editor uses an X11 window, and opening it under native
Wayland can crash MuseScore. The app-menu entry lets the wrapper choose the
platform. Hyprland sets `xwayland.force_zero_scaling = true`, and the installed
wrapper queries `hyprctl -j monitors` each time MuseScore starts. It sets
`QT_SCALE_FACTOR` to the focused monitor's scale (or the first monitor if none
is focused), and `QT_FONT_DPI=96` for the official build's `xcb` backend.
Qt renders the UI at full resolution instead of Hyprland stretching it.
Existing scale/DPI environment overrides are respected. Detection uses
`hyprctl` and `python3`, with a two-second timeout and a fallback scale of 1
if detection is unavailable. Restart MuseScore after changing displays or
scaling; its XWayland scale does not update while moving between monitors.
The Hyprland setting affects all XWayland windows; other X11 apps may need
their own toolkit scaling.
Plugin editors have their own scaling support and may still appear small or
pixelated even when MuseScore itself is sharp.
You can explicitly test native Wayland with
`MU_QT_QPA_PLATFORM=wayland ~/.local/bin/mscore`, or force XWayland with
`MU_QT_QPA_PLATFORM=xcb ~/.local/bin/mscore`. Fully quit and reopen MuseScore
after installing the launcher changes.

The installer also sets MuseScore 4's audio driver to `ALSA` and output device
to `pulse`, avoiding the startup freeze when reopening the default ALSA device.
These two settings are merged into `MuseScore/MuseScore4.ini`, preserving other
preferences and backing up the previous file when it changes. Close MuseScore
before installing so it does not overwrite the settings on exit. On Arch this
route requires `alsa-plugins` and a PulseAudio-compatible server such as
`pipewire-pulse`.

For a reverb effect similar to MuseFX, run `./install.sh --musescore-reverb`.
This installs Arch's [`dragonfly-reverb-vst3`](https://archlinux.org/packages/extra/x86_64/dragonfly-reverb-vst3/)
package using `sudo pacman -S --needed` and installs the official MuseScore
build with `install-musescore.sh`. The Arch MuseScore build can omit VST hosting,
so installing the plugin alone is insufficient. The launcher prefers the official
build under `${XDG_DATA_HOME:-~/.local/share}/musescore-official/current`, falling
back to `/usr/bin/mscore` when absent. The official AppImage is checked against
GitHub's SHA-256 digest and extracted so FUSE is not required. It shares your
existing MuseScore preferences and leaves the distro package installed.
The helper pins version 4.7.5 and its SHA-256 hashes for x86_64/aarch64;
pass a release tag to it to update deliberately. Close MuseScore before running
the reverb setup. It backs up an existing plugin registry, registers Dragonfly
Hall Reverb with a 30 second timeout, and verifies that MuseScore reports the
effect as enabled. Registration verifies loading, not interactive editor
compatibility; the launcher uses XWayland for VST editors. Rerunning the command reuses the installed official build.
Arch's Dragonfly package follows your configured pacman repositories.
It can be combined with the other
installer options, and `--dry-run` only previews the installation.
Use MuseScore Studio 4.6 or newer for
[Linux VST3 support](https://musescore.org/en/4.6).
Fully quit and reopen MuseScore after installing, open the Mixer (`F10`),
and select **Dragonfly Hall Reverb** in an **Audio FX** slot. For shared
reverb, put it on an Aux channel and adjust each instrument's send level.
Avoid stacking it with an existing reverb unless intended. Save the score
to retain the effect; installing the plugin does not change existing scores
or automatically enable it. MuseScore's built-in **Muse Reverb** is also
available without installing an extra package.

## Sonora on Arch Linux

Run `./install-sonora.sh` from this checkout as your normal user. It downloads
the latest stable release from [Falconbird18/Sonora](https://github.com/Falconbird18/Sonora/releases),
verifies the binary against GitHub's SHA-256 digest, and repackages the official
Debian binary as `sonora-bin` for pacman. No Rust or Node build is needed.

Install prerequisites if needed:

```bash
sudo pacman -S --needed base-devel curl python libarchive
./install-sonora.sh
```

The installer uses makepkg to install runtime dependencies and the package,
with sudo requested when needed. It includes the upstream app menu entry,
icons and license, and selects native Wayland in Wayland sessions for sharp
HiDPI rendering. X11 sessions remain supported.

Rerun the installer to update, or choose a release with
`./install-sonora.sh --tag V1.2.2`. Use `--build-only` to build without installing
(runtime dependencies must already be installed). Packages are saved under
`${XDG_CACHE_HOME:-$HOME/.cache}/sonora-installer`.

The selected release must provide a `.deb` for your architecture and a GitHub
SHA-256 digest. The current V1.2.2 release provides x86_64 binaries only; the
installer also recognizes arm64 releases if those are published later.

Launch with `sonora` or the app menu. Remove with `sudo pacman -Rns sonora-bin`;
your app data is retained.

## Credits
Thanks to [PoSayDone](https://github.com/PoSayDone) for the base ags widget. 
