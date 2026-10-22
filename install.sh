#!/usr/bin/env bash
set -euo pipefail
shopt -s dotglob nullglob
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DRY_RUN=false
INSTALL_KEYD=false
INSTALL_PACKAGES=false
usage() {
    cat <<'HELP'
Usage: ./install.sh [--dry-run] [--packages] [--keyd]
Install every entry in this checkout's .config and bundled user assets.
Existing directories are merged; replaced entries are backed up.
  --dry-run   Preview without changing files or installing packages
  --packages Install core desktop dependencies using pacman (Arch Linux)
  --keyd     Install and enable keyd with the bundled keyboard layout
  --help     Show help
HELP
}
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --packages) INSTALL_PACKAGES=true ;;
        --keyd) INSTALL_KEYD=true ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ $EUID == 0 && $DRY_RUN == false ]]; then
    echo 'Run as your normal user; sudo is requested only for system changes.' >&2
    exit 1
fi
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
for dir in "$HOME" "$CONFIG_HOME" "$DATA_HOME" "$STATE_HOME"; do
    [[ $dir == /* ]] || { echo "Expected an absolute path: $dir" >&2; exit 1; }
done
[[ -d $REPO_DIR/.config ]] || { echo 'Missing .config in checkout.' >&2; exit 1; }
BACKUP_DIR=
ACTION=Installing
if $DRY_RUN; then ACTION='Would install'; fi
backup() {
    local dest=$1 relative=$2
    if $DRY_RUN; then
        printf 'Would back up: %s\n' "$dest"
        return
    fi
    if [[ -z $BACKUP_DIR ]]; then
        mkdir -p -- "$STATE_HOME/dotfiles/backups"
        BACKUP_DIR=$(mktemp -d "$STATE_HOME/dotfiles/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    fi
    mkdir -p -- "$(dirname -- "$BACKUP_DIR/$relative")"
    mv -- "$dest" "$BACKUP_DIR/$relative"
}
# Merge without following destination symlinks; retain unrelated live settings.
install_entry() {
    local src=$1 dest=$2 relative=$3 child
    if [[ $src -ef $dest ]]; then
        printf 'Already installed: %s\n' "$dest"
        return
    fi
    if [[ -d $src && ! -L $src ]]; then
        if [[ -L $dest || ( -e $dest && ! -d $dest ) ]]; then
            backup "$dest" "$relative"
        fi
        if ! $DRY_RUN; then mkdir -p -- "$dest"; fi
        for child in "$src"/*; do
            install_entry "$child" "$dest/${child##*/}" "$relative/${child##*/}"
        done
    else
        if [[ -f $src && ! -L $src && -f $dest && ! -L $dest ]] && cmp -s -- "$src" "$dest" && [[ $(stat -c %a -- "$src") == "$(stat -c %a -- "$dest")" ]]; then
            return
        fi
        if [[ -L $src && -L $dest ]] && [[ $(readlink -- "$src") == "$(readlink -- "$dest")" ]]; then
            return
        fi
        if [[ -e $dest || -L $dest ]]; then backup "$dest" "$relative"; fi
        printf '%s: %s\n' "$ACTION" "$dest"
        if ! $DRY_RUN; then cp -a -- "$src" "$dest"; fi
    fi
}
# if $INSTALL_PACKAGES || $INSTALL_KEYD; then
#     command -v pacman >/dev/null || { echo 'Package installation requires Arch Linux (pacman).' >&2; exit 1; }
#     packages=()
#     if $INSTALL_PACKAGES; then
#         packages+=(hyprland kitty fish starship qt6-wayland hyprpicker hyprlock hypridle
#             wl-clipboard brightnessctl bluez-utils cliphist grim slurp playerctl
#             xdg-desktop-portal-hyprland)
#     fi
#     if $INSTALL_KEYD; then packages+=(keyd); fi
#     if $DRY_RUN; then
#         printf 'Would install packages: %s\n' "${packages[*]}"
#     else
#         sudo pacman -S --needed "${packages[@]}"
#     fi
# fi
install_entry "$REPO_DIR/.config" "$CONFIG_HOME" config
for name in bin share; do
    src="$REPO_DIR/.local/$name"
    [[ -d $src ]] || continue
    if [[ $name == share ]]; then dest=$DATA_HOME; else dest=$HOME/.local/bin; fi
    install_entry "$src" "$dest" "local/$name"
done
# for name in .icons .spicetify wallpapers; do
#     [[ -d $REPO_DIR/$name ]] || continue
#     if [[ $name == wallpapers ]]; then dest=$HOME/Pictures/wallpapers; else dest=$HOME/$name; fi
#     if ! $DRY_RUN; then mkdir -p -- "$(dirname -- "$dest")"; fi
#     install_entry "$REPO_DIR/$name" "$dest" "assets/$name"
# done
if $INSTALL_KEYD; then
    if $DRY_RUN; then
        echo 'Would back up /etc/keyd/default.conf, install the keyboard layout, and enable/reload keyd.'
    else
        sudo mkdir -p /etc/keyd
        if sudo test -e /etc/keyd/default.conf || sudo test -L /etc/keyd/default.conf; then
            keyd_backup=$(sudo mktemp -d /etc/keyd/dotfiles-backup-XXXXXX)
            sudo cp -a /etc/keyd/default.conf "$keyd_backup/default.conf"
            printf 'Keyboard backup: %s/default.conf\n' "$keyd_backup"
        fi
        sudo cp -- "$REPO_DIR/etc/keyd/default.conf" /etc/keyd/default.conf
        sudo usermod -aG keyd "$(id -un)"
        sudo systemctl enable --now keyd
        sudo keyd reload
        echo 'Log out and back in to apply keyd group membership.'
    fi
fi
if ! $DRY_RUN && command -v update-desktop-database >/dev/null && [[ -d $DATA_HOME/applications ]]; then
    update-desktop-database "$DATA_HOME/applications"
fi
[[ -z $BACKUP_DIR ]] || printf 'Backups: %s\n' "$BACKUP_DIR"
hyprctl reload
echo 'Done. Restart affected apps; log in again to pick up session environment changes.'
