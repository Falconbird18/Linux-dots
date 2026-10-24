#!/usr/bin/env bash
set -euo pipefail
shopt -s dotglob nullglob
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DRY_RUN=false
INSTALL_KEYD=false
INSTALL_MUSESCORE_REVERB=false
DISPLAY_SETTINGS=
usage() {
    cat <<'HELP'
Usage: ./install.sh [--dry-run] [--keyd] [--musescore-reverb] [--display=auto|preconfigured]
Install this checkout's configs, launchers, and desktop entries.
Existing directories are merged; replaced entries are backed up.
  --dry-run   Preview without changing files or installing packages
  --keyd     Install and enable keyd with the bundled keyboard layout
  --musescore-reverb Install Dragonfly VST3 reverbs for MuseScore 4.6+ (Arch Linux)
  --display=auto          Generate portable display settings (default without a terminal)
  --display=preconfigured Use the bundled display resolution, scaling, and HDR settings
  --help     Show help
HELP
}
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --keyd) INSTALL_KEYD=true ;;
        --musescore-reverb) INSTALL_MUSESCORE_REVERB=true ;;
        --display=auto|--display=preconfigured)
            selected_display=${arg#*=}
            if [[ -n $DISPLAY_SETTINGS && $DISPLAY_SETTINGS != "$selected_display" ]]; then
                echo 'Choose only one display settings mode.' >&2
                exit 2
            fi
            DISPLAY_SETTINGS=$selected_display
            ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ $EUID == 0 && $DRY_RUN == false ]]; then
    echo 'Run as your normal user; sudo is requested only for system changes.' >&2
    exit 1
fi
if [[ -z $DISPLAY_SETTINGS ]]; then
    DISPLAY_SETTINGS=auto
    if [[ -t 0 ]]; then
        printf 'Display settings: [1] Auto-generate for this computer (default), [2] Preconfigured laptop settings\n'
        read -r -p 'Choose [1/2]: ' display_choice || display_choice=
        case "$display_choice" in
            ''|1|auto) ;;
            2|preconfigured) DISPLAY_SETTINGS=preconfigured ;;
            *) echo 'Invalid display settings choice.' >&2; exit 2 ;;
        esac
    fi
fi
printf 'Display settings: %s\n' "$DISPLAY_SETTINGS"
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
    if [[ $relative == config/hypr/dms/outputs.lua && $DISPLAY_SETTINGS == auto ]]; then
        src=$GENERATED_OUTPUTS
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
if $INSTALL_MUSESCORE_REVERB; then
    if $DRY_RUN; then
        echo 'Would install dragonfly-reverb-vst3 (pacman) and the official VST-enabled MuseScore build.'
    else
        command -v pacman >/dev/null || { echo 'MuseScore reverb installation requires Arch Linux (pacman).' >&2; exit 1; }
        sudo pacman -S --needed dragonfly-reverb-vst3
        "$REPO_DIR/install-musescore.sh"
        echo 'Registering Dragonfly Hall Reverb with official MuseScore (30 second limit)...'
        plugin=/usr/lib/vst3/DragonflyHallReverb.vst3
        [[ -d $plugin ]] || { echo "Missing VST3 bundle: $plugin" >&2; exit 1; }
        if pgrep -x mscore >/dev/null || pgrep -x mscore4portable >/dev/null; then
            echo 'Close MuseScore, then rerun with --musescore-reverb to register the effect.' >&2
            exit 1
        fi
        registry=$DATA_HOME/MuseScore/MuseScore4/known_audio_plugins.json
        if [[ -f $registry ]]; then
            registration_backup=$(mktemp "${registry}.backup-XXXXXX")
            cp -p -- "$registry" "$registration_backup"
        fi
        QT_QPA_PLATFORM=offscreen MU_QT_QPA_PLATFORM=offscreen timeout 30s \
            "$DATA_HOME/musescore-official/current/AppRun" --register-audio-plugin "$plugin"
        python3 - "$registry" "$plugin" <<'PY_CHECK'
import json, sys
with open(sys.argv[1]) as f:
    plugins = json.load(f)
if not any(p.get('path') == sys.argv[2] and p.get('enabled')
           and p.get('meta', {}).get('id') == 'DragonflyHallReverb' for p in plugins):
    sys.exit('Dragonfly Hall Reverb registration failed; inspect MuseScore audio plugin logs.')
print('Verified: Dragonfly Hall Reverb is enabled in MuseScore.')
PY_CHECK
    fi
fi
# Keep the checkout's hardware profile intact. Generate only the installed copy.
GENERATED_OUTPUTS=
trap '[[ -z $GENERATED_OUTPUTS || $GENERATED_OUTPUTS == /dev/null ]] || rm -f -- "$GENERATED_OUTPUTS"' EXIT
if [[ $DISPLAY_SETTINGS == auto ]]; then
    if $DRY_RUN; then
        echo 'Would generate display settings: preferred mode, automatic position and per-monitor scale; no forced HDR/VRR.'
        # install_entry only compares/prints this source during a dry run.
        GENERATED_OUTPUTS=/dev/null
    else
        GENERATED_OUTPUTS=$(mktemp)
        cat > "$GENERATED_OUTPUTS" <<'OUTPUTS'
-- Generated by Linux-dots install.sh --display=auto.
-- Hyprland detects preferred modes and scaling when each display connects.
-- Adjust displays in DMS to save a custom layout for this computer.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
OUTPUTS
        chmod 644 "$GENERATED_OUTPUTS"
    fi
fi
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
    echo 'MuseScore 4.6+: restart, open Mixer (F10), and select Dragonfly Hall Reverb in an Audio FX slot.'
    echo 'For shared reverb, use an Aux channel and adjust instrument sends; save the score to retain the effect.'
fi
echo 'Done. Restart affected apps; run hyprctl reload when ready to apply Hyprland changes.'
echo 'Log in again to pick up session environment changes.'
