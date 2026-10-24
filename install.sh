#!/usr/bin/env bash
set -euo pipefail
shopt -s dotglob nullglob
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DRY_RUN=false
ACCEPT_DEFAULTS=false
CONFIGS_ONLY=false
INSTALL_DESKTOP=true
INSTALL_KEYD=true
INSTALL_MUSESCORE=true
INSTALL_MUSESCORE_REVERB=true
INSTALL_WALLPAPERS=true
APP_GROUPS=(everyday productivity creative development)
usage() {
    cat <<'HELP'
Usage: ./install.sh [--dry-run] [--yes]
An interactive guide to device profiles, display settings, apps and config sync.
  --dry-run   Preview your menu choices without changing anything
  --yes       Use detected hardware and suggested defaults without questions
  --help      Show help
Surface kernel/camera setup is separate: Surface-11-pro/install-surface11.sh
HELP
}
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes) ACCEPT_DEFAULTS=true ;;
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
model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case "$model" in
    *Surface*Pro*11*) PROFILE=surface ;;
    *HP*Pavilion*15*) PROFILE=hp ;;
    *) PROFILE=other ;;
esac
source "$REPO_DIR/scripts/setup-menu.sh"
configure_setup
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
install_musescore_settings() {
    local src=$1 dest=$2 relative=$3 merged
    if $DRY_RUN; then
        printf 'Would merge MuseScore audio settings: %s\n' "$dest"
        return
    fi
    merged=$(mktemp)
    # Only the bundled [io] keys override live preferences. Keep other keys,
    # sections, and comments, including the user's theme and recent projects.
    if ! awk '
        FILENAME == ARGV[1] {
            if ($0 ~ /^[^#;[][^=]*=/) {
                key=$0; sub(/=.*/, "", key)
                values[key]=$0; order[++count]=key
            }
            next
        }
        /^\[/ {
            in_io=($0 ~ /^\[io\][[:space:]]*$/)
            print
            if (in_io && !found++) {
                for (i=1; i<=count; i++) print values[order[i]]
            }
            next
        }
        in_io {
            key=$0; sub(/=.*/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key in values && index($0, "=")) next
        }
        { print }
        END {
            if (!found) {
                print "\n[io]"
                for (i=1; i<=count; i++) print values[order[i]]
            }
        }
    ' "$src" "$dest" > "$merged"; then
        rm -f -- "$merged"
        return 1
    fi
    if cmp -s -- "$merged" "$dest"; then
        rm -f -- "$merged"
        return
    fi
    chmod --reference="$dest" "$merged"
    backup "$dest" "$relative"
    cp -p -- "$merged" "$dest"
    rm -f -- "$merged"
    printf 'Merged MuseScore audio settings: %s\n' "$dest"
}
install_entry() {
    local src=$1 dest=$2 relative=$3 child
    if ! $INSTALL_MUSESCORE; then
        case "$relative" in
            config/MuseScore|local/bin/mscore|local/share/applications/org.musescore.MuseScore.desktop) return ;;
        esac
    fi
    if [[ $relative == config/hypr/dms/outputs.lua ]]; then
        if [[ $DISPLAY_SETTINGS == keep && -f $dest ]]; then
            printf 'Keeping device display settings: %s\n' "$dest"
            return
        fi
        case "$DISPLAY_SETTINGS" in
            auto) src=$GENERATED_OUTPUTS ;;
            hp|surface) src=$REPO_DIR/profiles/$DISPLAY_SETTINGS-outputs.lua ;;
        esac
    fi
    if [[ $src -ef $dest ]]; then
        printf 'Already installed: %s\n' "$dest"
        return
    fi
    if [[ $relative == config/MuseScore/MuseScore4.ini && -f $dest && ! -L $dest ]]; then
        install_musescore_settings "$src" "$dest" "$relative"
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
# Prevent a running app from overwriting the merged audio preferences.
if $INSTALL_MUSESCORE && ! $DRY_RUN && { pgrep -x mscore >/dev/null || pgrep -x mscore4portable >/dev/null; }; then
    echo 'Quit MuseScore before installing or syncing its audio settings.' >&2
    exit 1
fi
if ! $CONFIGS_ONLY; then
    source "$REPO_DIR/scripts/packages.sh"
    install_packages
fi
# Keep the checkout's hardware profile intact. Generate only the installed copy.
GENERATED_OUTPUTS=
trap '[[ -z $GENERATED_OUTPUTS || $GENERATED_OUTPUTS == /dev/null ]] || rm -f -- "$GENERATED_OUTPUTS"' EXIT
if [[ $DISPLAY_SETTINGS == keep && ! -f $CONFIG_HOME/hypr/dms/outputs.lua ]]; then
    DISPLAY_SETTINGS=$PROFILE_DISPLAY
fi
if [[ $DISPLAY_SETTINGS == auto ]]; then
    if $DRY_RUN; then
        echo 'Would generate display settings: preferred mode, automatic position and per-monitor scale; no forced HDR/VRR.'
        # install_entry only compares/prints this source during a dry run.
        GENERATED_OUTPUTS=/dev/null
    else
        GENERATED_OUTPUTS=$(mktemp)
        cat > "$GENERATED_OUTPUTS" <<'OUTPUTS'
-- Generated by Linux-dots install.sh (automatic display settings).
-- Hyprland detects preferred modes and scaling when each display connects.
-- Adjust displays in DMS to save a custom layout for this computer.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
OUTPUTS
        chmod 644 "$GENERATED_OUTPUTS"
    fi
fi
heading 'Installing configuration'
install_entry "$REPO_DIR/.config" "$CONFIG_HOME" config
# Only supporting scripts and desktop entries belong in the user data install.
# Do not traverse .local/share wholesale (fonts/icons can contain many files).
for relative in .local/bin .local/share/applications; do
    src="$REPO_DIR/$relative"
    [[ -d $src ]] || continue
    case "$relative" in
        .local/bin) dest=$HOME/.local/bin ;;
        .local/share/applications) dest=$DATA_HOME/applications ;;
    esac
    if ! $DRY_RUN; then mkdir -p -- "$(dirname -- "$dest")"; fi
    install_entry "$src" "$dest" "${relative#.}"
done
if $INSTALL_WALLPAPERS && [[ -d $REPO_DIR/wallpapers ]]; then
    install_entry "$REPO_DIR/wallpapers" "$DATA_HOME/backgrounds/Tempora" backgrounds/Tempora
fi
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
    echo 'Updating desktop entry database (10 second limit)...'
    if ! timeout 10s update-desktop-database "$DATA_HOME/applications"; then
        echo 'Desktop database update failed or timed out; configs are installed.' >&2
    fi
fi
[[ -z $BACKUP_DIR ]] || printf 'Backups: %s\n' "$BACKUP_DIR"
if $INSTALL_MUSESCORE_REVERB; then
    source "$REPO_DIR/scripts/musescore-audio.sh"
    register_reverbs
    echo 'MuseScore 4.6+: restart, open Mixer (F10), and select Dragonfly Hall Reverb in an Audio FX slot.'
    echo 'For shared reverb, use an Aux channel and adjust instrument sends; save the score to retain the effect.'
fi
heading 'Setup complete'
echo 'Restart affected apps; run hyprctl reload when ready to apply Hyprland changes.'
echo 'Log in again to pick up session environment changes.'
