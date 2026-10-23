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
./install.sh              # install configs and bundled user assets
./install.sh --packages   # also install core desktop dependencies on Arch
./install.sh --keyd       # also install/enable the bundled keyd keyboard layout
./install.sh --musescore-reverb # also install Dragonfly VST3 reverbs on Arch
```

`install-dots.sh` is an alias for the same installer and accepts the same options.
Use `--packages --keyd` together to include both optional system setup steps.
The installer uses this checkout, including local edits; it does not download an
older copy of the dots or run third-party installers.

Every entry in `.config` is installed, including hidden files and newly added
folders. Existing directories are merged, and unrelated files are kept. Each
replaced file or symlink is moved to a unique backup directory under
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/backups` with its relative path retained.
The backup location is printed when installation finishes. To restore an entry,
copy it from that directory to its original destination.

Bundled `.local/bin`, `.local/share`, `.icons`, `.spicetify`, and wallpapers are
also installed. Wallpapers go to `~/Pictures/wallpapers`. The installer respects
`XDG_CONFIG_HOME` and `XDG_DATA_HOME`. Repeat runs skip identical files.
System settings are only changed with `--keyd`; the previous keyboard layout is
backed up in `/etc/keyd/dotfiles-backup-*`. `--packages` installs core desktop
tools; optional apps and the current DMS shell must be installed separately.

### MuseScore at 200% scaling

The bundled app-menu override and `~/.local/bin/mscore` wrapper select native
Wayland using `MU_QT_QPA_PLATFORM=wayland`. MuseScore overrides the ordinary
`QT_QPA_PLATFORM` setting, which can leave it rendering through XWayland and
looking blurry. See the [upstream explanation](https://github.com/musescore/MuseScore/issues/30247).
Install the dots, then fully quit and reopen MuseScore. On Arch, native Wayland
requires `qt6-wayland` (included with `--packages`). Ensure `~/.local/bin` is in
`PATH` for terminal launches. The app-menu entry works without this PATH change.
If you encounter a MuseScore Wayland bug, use
`MU_QT_QPA_PLATFORM=xcb ~/.local/bin/mscore` as a temporary fallback.

The installer also sets MuseScore 4's audio driver to `ALSA` and output device
to `pulse`, avoiding the startup freeze when reopening the default ALSA device.
These two settings are merged into `MuseScore/MuseScore4.ini`, preserving other
preferences and backing up the previous file when it changes. Close MuseScore
before installing so it does not overwrite the settings on exit. On Arch this
route requires `alsa-plugins` and a PulseAudio-compatible server such as
`pipewire-pulse`.

For a reverb effect similar to MuseFX, run `./install.sh --musescore-reverb`.
This installs Arch's [`dragonfly-reverb-vst3`](https://archlinux.org/packages/extra/x86_64/dragonfly-reverb-vst3/)
package using `sudo pacman -S --needed`; it can be combined with the other
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
