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

  
## Installation and keeping laptops in sync

On a fully updated Arch installation, run as your normal user:

```bash
./install.sh
```

The guide walks through four steps, with Enter accepting the suggested choice:

1. **Device and installation:** Surface Pro 11, HP Pavilion 15, or Other;
   full setup or configuration-only sync.
2. **Display:** keep the current layout, apply the saved device profile, or use
   automatic modes and scaling.
3. **Components and apps:** yes/no choices for desktop packages, keyd, MuseScore
   and Dragonfly, app groups, and wallpapers.
4. **Review:** see the complete selection and confirm before anything changes.

The saved **HP Pavilion 15-eh3xxx** profile captures the active internal display:
1920×1080 at 60.164 Hz, 100% scaling, position 0×0, no rotation, SDR/sRGB,
10-bit output and VRR off. It lives in `profiles/hp-outputs.lua`. The Surface
profile keeps its 2880×1920 at 120 Hz, 200%, HDR layout in
`profiles/surface-outputs.lua`. Both allow additional monitors to use preferred
modes. Other uses automatic resolution and scaling. Keeping a layout uses the
selected device defaults if no installed display configuration exists.

Shared setup never builds a kernel. Run
`Surface-11-pro/install-surface11.sh` separately **only on the supported Intel
Surface Pro 11 for Business** for its kernel and cameras. Follow its reboot
instructions and rerun it to complete camera setup.

### Default apps

These groups are curated from the apps installed on the HP. Desktop, MuseScore,
and the first four app groups default to **yes**; Gaming defaults to **no**.
Each group can be declined independently.

| Group | Included apps and tools |
| --- | --- |
| Desktop | Hyprland/DMS, Kitty, Fish, Starship, Dolphin, Ark, clipboard and screenshot tools, portals, Bluetooth tools, fonts, icon/cursor themes |
| MuseScore | Official package-managed MuseScore, Dragonfly VST3 reverbs, Muse Sounds Manager, ALSA/PipeWire bridges |
| Everyday | Firefox, Chromium, Thunderbird, Discord, VLC, Spotify, Spicetify, FreeTube, Proton Pass and Authenticator |
| Productivity | LibreOffice, Okular, calculator, calendar, Anki, Zotero, Super Productivity, scanning and printer tools |
| Creative | GIMP, Inkscape, Krita, Kdenlive, HandBrake, Darktable, Blender, Audacity, LMMS, LilyPond, Scribus, Picard |
| Development | Zed, Neovim, Git tools, Node, pnpm, Yarn, Python tools, Rustup, CMake, Doxygen, Docker, Godot, Android Studio |
| Gaming | Luanti, Wine, Wine Mono, Winetricks |

Edit the plain package lists in `packages/` to change shared app defaults. Each
group has a `.repo` list for pacman and an `.aur` list for paru/yay. The installer
uses `--needed` and skips installed AUR packages. Additional desktop
environments, recovery tools, hardware drivers and bootloaders are excluded.
Docker and printing system services are not enabled automatically; installing
their clients does not grant privileged group membership. Rustup and Android
Studio may need first-launch SDK/toolchain setup. Spicetify is installed but the
script does not run its theme modification commands. Sonora remains separate.

The only flags are:

```bash
./install.sh --dry-run        # walk through the guide and preview changes
./install.sh --yes            # detect device and accept all suggested defaults
./install.sh --yes --dry-run  # preview defaults without questions
./install.sh --help
```

Old component/profile flags have been removed in favor of the guide. Without
`--yes`, reaching the end of input cancels before installation. Colors are used
only in capable terminals; `NO_COLOR=1` disables them.

Missing AUR packages are built with paru or yay; if neither exists, the script
builds paru first as the normal user. The desktop uses `hyprland-git` for the
bundled Lua configuration and `dms-shell-git` for Dux Shell. Initial setup needs
internet and can take time to compile/download, especially creative/development
apps. Sudo authentication is still required for system changes. Conflicting or
architecture-incompatible packages may need manual resolution. Run
`sudo pacman -Syu` before initial setup; the installer does not refresh databases
partially or replace your login manager, bootloader, or login shell.

### Terminal appearance

Kitty uses Space Mono (provided by the desktop group's
`ttf-google-fonts-typewolf` package), rounded tabs, and 90% background opacity.
Starship uses ANSI palette colors so it follows the terminal's Material You colors.
Config sync installs both configurations and removes the legacy AGS palette loader
from the bundled Fish config.

Enable Kitty theming in DMS to generate `~/.config/kitty/dank-theme.conf` and
`dank-tabs.conf`. Kitty loads these when present, with a bundled Material You
fallback before the first generation. Sync preserves DMS-generated files; opacity
and tab shape stay controlled by `kitty.conf`. Open a new terminal after syncing.
Config-only sync assumes the desktop fonts and terminal tools are already installed.

### Sync between laptops

Commit and push intended shared edits from one laptop, then on the other:

```bash
git pull --ff-only
./install.sh
```

Choose **Sync configuration only** and **Keep this computer’s layout**. Package
installation, services, keyd and plugin scanning are skipped. Select the saved
device profile in the Display step whenever you want to restore those settings.
This is a one-way checkout-to-home sync; copy intended changes made by apps in
your home directory back into the repository deliberately before sharing them.
The installer never commits, pushes or changes your Git checkout automatically.

Existing directories are merged; unrelated files are retained. Replaced files
and symlinks are backed up under
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/backups`; the location is printed.
Identical files are skipped. Config paths respect `XDG_CONFIG_HOME` and
`XDG_DATA_HOME`. Selected wallpapers go to
`${XDG_DATA_HOME:-~/.local/share}/backgrounds/Tempora`. Keyd's previous system
configuration is backed up separately. Restart affected apps or log in again;
the script does not reload the live Hyprland session automatically.

### MuseScore and Dragonfly

Quit MuseScore before installing or syncing. The installer merges only its
bundled audio keys into `MuseScore/MuseScore4.ini`, keeping your scores, other
preferences and MIDI settings. It selects **ALSA → pulse**, routed through
`alsa-plugins` to `pipewire-pulse`. This avoids the default ALSA/PipeWire device
reopen that hung on the HP. Both bridges are installed automatically.

The `~/.local/bin/mscore` wrapper uses `/usr/bin/mscore` from the installed
`musescore-bin` package. `install-musescore.sh` has been removed. The wrapper
no longer uses the private `~/.local/share/musescore-official` download; any
previous copy remains on disk but is unused. The Arch repository `musescore`
build may lack VST3 hosting, so shared setup uses the package-managed official
binary instead. Fish adds `~/.local/bin` to PATH for the wrapper and app menu.

In Wayland sessions the wrapper defaults to XWayland (`xcb`) because Dragonfly
editors use X11 windows. Both Qt platform variables are set consistently.
With Hyprland's `force_zero_scaling`, it reads the focused monitor scale with a
two-second timeout and supplies Qt's scale/DPI; explicit scale overrides are
preserved. Restart MuseScore after changing monitor scale. To test native
Wayland explicitly: `MU_QT_QPA_PLATFORM=wayland mscore`.

Full setup backs up the plugin registry, registers all installed Dragonfly VST3
effects with a 30-second limit per effect, and verifies they are enabled.
Registration does not automatically apply reverb to scores. Open Mixer (`F10`),
select **Dragonfly Hall Reverb** in an Audio FX slot or Aux channel, adjust sends,
and save the score. Plugin registration alone does not prove audible playback
or editor compatibility on every machine.

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
