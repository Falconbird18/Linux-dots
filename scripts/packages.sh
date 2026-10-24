# Shared Arch dependencies. Sourced by install.sh, not a standalone installer.
read_package_group() {
    local group=$1 package
    while read -r package; do
        [[ -z $package || $package == \#* ]] || PACKAGES+=("$package")
    done < "$REPO_DIR/packages/$group.repo"
    while read -r package; do
        [[ -z $package || $package == \#* ]] || AUR_PACKAGES+=("$package")
    done < "$REPO_DIR/packages/$group.aur"
}
install_packages() {
    local pkg helper= group
    local -a missing=() PACKAGES=(git base-devel python curl desktop-file-utils) AUR_PACKAGES=()
    if $INSTALL_DESKTOP; then read_package_group desktop; fi
    if $INSTALL_DESKTOP || $INSTALL_MUSESCORE; then
        PACKAGES+=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-plugins)
    fi
    if $INSTALL_MUSESCORE; then
        PACKAGES+=(dragonfly-reverb-vst3 qt6-wayland xorg-xwayland)
        AUR_PACKAGES+=(musescore-bin muse-sounds-manager-bin)
    fi
    if $INSTALL_KEYD; then PACKAGES+=(keyd); fi
    for group in "${APP_GROUPS[@]}"; do read_package_group "$group"; done
    heading 'Installing selected packages'
    if $DRY_RUN; then
        printf 'Would install Arch packages: %s\n' "${PACKAGES[*]}"
        printf 'Would install missing AUR packages: %s\n' "${AUR_PACKAGES[*]:-none}"
        return
    fi
    command -v pacman >/dev/null || { echo 'Package setup requires Arch Linux.' >&2; exit 1; }
    # No database refresh here: first fully update Arch to avoid partial upgrades.
    sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"
    for pkg in "${AUR_PACKAGES[@]}"; do
        pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        for helper in paru yay; do
            if command -v "$helper" >/dev/null; then break; fi
            helper=
        done
        if [[ -z $helper ]]; then
            local work
            work=$(mktemp -d)
            git clone --depth 1 https://aur.archlinux.org/paru.git "$work/paru"
            (cd "$work/paru" && makepkg -si --needed --noconfirm)
            rm -rf -- "$work"
            helper=paru
        fi
        "$helper" -S --needed --noconfirm "${missing[@]}"
    fi
    if $INSTALL_DESKTOP || $INSTALL_MUSESCORE; then
        systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
    fi
    if $INSTALL_DESKTOP; then systemctl --user enable dms.service; fi
    # Docker and printing apps are installed as clients; their system services
    # and privileged group memberships are not enabled implicitly.
}
