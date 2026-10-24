# Interactive setup UI, kept separate from file and package installation.
ACCENT= RESET= BOLD=
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    ACCENT=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
fi
heading() { printf '\n%s%s%s\n' "$ACCENT$BOLD" "$*" "$RESET"; }
# Assign directly so prompts remain visible and answers survive in this shell.
choose() {
    local variable=$1 prompt=$2 default=$3 allowed=$4 answer
    while true; do
        printf '%s [%s]: ' "$prompt" "$default"
        if ! read -r answer; then
            echo 'Input ended. No installation started; use --yes to accept defaults.' >&2
            exit 2
        fi
        answer=${answer:-$default}
        case " $allowed " in
            *" $answer "*) printf -v "$variable" '%s' "$answer"; return ;;
        esac
        printf 'Please choose one of: %s\n' "$allowed"
    done
}
ask_yes_no() {
    local variable=$1 prompt=$2 default=${3:-y} answer
    while true; do
        printf '%s [%s]: ' "$prompt" "$([[ $default == y ]] && echo Y/n || echo y/N)"
        if ! read -r answer; then echo 'Input ended. No installation started.' >&2; exit 2; fi
        case "${answer:-$default}" in
            y|Y|yes|YES) printf -v "$variable" true; return ;;
            n|N|no|NO) printf -v "$variable" false; return ;;
            *) echo 'Please enter yes or no.' ;;
        esac
    done
}
configure_setup() {
    local choice default=3 group confirmed
    heading 'Tempora · Your Arch workspace'
    printf 'Shared setup for Surface, HP and other computers.\n'
    case "$PROFILE" in surface) default=1 ;; hp) default=2 ;; esac
    if ! $ACCEPT_DEFAULTS; then
        heading '1 / 4 · Device & installation'
        printf '  1  Surface Pro 11\n  2  HP Pavilion 15\n  3  Other computer\n'
        choose choice 'Device' "$default" '1 2 3'
        case "$choice" in 1) PROFILE=surface ;; 2) PROFILE=hp ;; 3) PROFILE=other ;; esac
        printf '\n  1  Full setup — packages and configuration\n  2  Sync configuration only — keep installed packages\n'
        choose choice 'Installation' 1 '1 2'
        [[ $choice != 2 ]] || CONFIGS_ONLY=true
    fi
    source "$REPO_DIR/profiles/$PROFILE.sh"
    DISPLAY_SETTINGS=$PROFILE_DISPLAY
    [[ ! -f $CONFIG_HOME/hypr/dms/outputs.lua ]] || DISPLAY_SETTINGS=keep
    if ! $ACCEPT_DEFAULTS; then
        heading '2 / 4 · Display'
        printf '  1  Keep this computer’s layout (use device defaults if none exists)\n'
        printf '  2  Apply saved %s display profile\n  3  Automatic modes and scaling\n' "$PROFILE"
        choose choice 'Display settings' 1 '1 2 3'
        case "$choice" in
            1) ;;
            2) DISPLAY_SETTINGS=$PROFILE_DISPLAY ;;
            3) DISPLAY_SETTINGS=auto ;;
        esac
    fi
    if $CONFIGS_ONLY; then
        INSTALL_KEYD=false
        INSTALL_MUSESCORE_REVERB=false
        INSTALL_DESKTOP=false
        APP_GROUPS=()
    elif ! $ACCEPT_DEFAULTS; then
        heading '3 / 4 · Components'
        ask_yes_no INSTALL_DESKTOP 'Install Hyprland, DMS, desktop tools and fonts?'
        ask_yes_no INSTALL_KEYD 'Install and enable your keyd keyboard layout?'
        ask_yes_no INSTALL_MUSESCORE 'Install MuseScore, Dragonfly reverbs and Muse Sounds Manager?'
        INSTALL_MUSESCORE_REVERB=$INSTALL_MUSESCORE
        APP_GROUPS=()
        printf '\nChoose app groups (Enter accepts the suggested answer).\n'
        printf '  Everyday: Firefox, Chromium, Thunderbird, Discord, VLC, Spotify, FreeTube, Proton\n'
        ask_yes_no confirmed 'Install everyday apps?'
        if $confirmed; then APP_GROUPS+=(everyday); fi
        printf '  Productivity: LibreOffice, Okular, Anki, Zotero, calendar and scanning tools\n'
        ask_yes_no confirmed 'Install productivity apps?'
        if $confirmed; then APP_GROUPS+=(productivity); fi
        printf '  Creative: GIMP, Inkscape, Krita, Kdenlive, Blender, Audacity, LMMS and more\n'
        ask_yes_no confirmed 'Install creative apps?'
        if $confirmed; then APP_GROUPS+=(creative); fi
        printf '  Development: Zed, Neovim, Node, Python, Rust, Docker, Godot, Android Studio\n'
        ask_yes_no confirmed 'Install development tools?'
        if $confirmed; then APP_GROUPS+=(development); fi
        printf '  Gaming: Luanti, Wine and Winetricks\n'
        ask_yes_no confirmed 'Install gaming tools?' n
        if $confirmed; then APP_GROUPS+=(gaming); fi
    fi
    if ! $ACCEPT_DEFAULTS; then
        ask_yes_no INSTALL_WALLPAPERS 'Copy the bundled wallpapers?'
    fi
    heading '4 / 4 · Review'
    printf '  Device:        %s\n  Display:       %s\n' "$PROFILE" "$DISPLAY_SETTINGS"
    printf '  Configs only:  %s\n  Desktop:       %s\n  Keyboard:      %s\n' "$CONFIGS_ONLY" "$INSTALL_DESKTOP" "$INSTALL_KEYD"
    printf '  MuseScore FX:  %s\n  Wallpapers:    %s\n' "$INSTALL_MUSESCORE_REVERB" "$INSTALL_WALLPAPERS"
    printf '  App groups:    %s\n' "${APP_GROUPS[*]:-none}"
    printf '  Preview only:  %s\n' "$DRY_RUN"
    printf '\nExisting files are backed up before replacement. Surface hardware setup stays separate.\n'
    if ! $ACCEPT_DEFAULTS; then
        ask_yes_no confirmed 'Continue with these choices?'
        if ! $confirmed; then echo 'Cancelled. Nothing changed.'; exit 0; fi
    fi
}
