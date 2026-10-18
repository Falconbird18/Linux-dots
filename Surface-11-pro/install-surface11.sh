#!/usr/bin/env bash
# Single entry point for the currently supported Intel Surface Pro 11 fixes.
# Run as the logged-in desktop user; individual privileged steps request sudo.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: bash install-surface11.sh [install|status|cameras|kernel|undo-cameras]
  install       Default: build patched kernel if needed; otherwise install cameras.
  status        Show detected hardware, kernel and camera service status.
  cameras       Install/repair standard webcams on the patched custom kernel.
  kernel        Build/install the patched kernel while booted into another kernel.
  undo-cameras  Remove the webcam bridge, keeping kernel drivers and packages.

Supports only Intel Surface Pro 11 for Business SKU 2103 on Arch-based Linux.
Keep the entire Surface-11-pro folder, including patches/ and helper scripts.
A kernel change requires a reboot: select the custom kernel, then run this same
command again. It will continue with the camera setup. Never automatically reboots.
HELP
}
mode=${1:-install}
case "$mode" in -h|--help|help) usage; exit 0;; esac
[[ $# -le 1 ]] || fail 'Expected one optional command; see --help.'
case "$mode" in install|status|cameras|kernel|undo-cameras) ;; *) usage >&2; exit 2;; esac
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user, not with sudo before the whole command.'
[[ $(uname -m) == x86_64 ]] || fail 'This is the Intel installer; Snapdragon/ARM models are unsupported.'
vendor=$(cat /sys/class/dmi/id/sys_vendor)
sku=$(cat /sys/class/dmi/id/product_sku)
[[ $vendor == 'Microsoft Corporation' && $sku == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] ||
  fail "Unsupported hardware: $vendor / $sku. Model-specific patches will not be applied."
command -v pacman >/dev/null || fail 'This installer currently supports Arch-based distributions only.'
command -v systemctl >/dev/null || fail 'systemd is required.'
for helper in build-linux-kernel.sh apply-imx681-patches.sh ensure-camera-module.sh setup-system-cameras.sh surface-camera-relay.sh loopback-writer.h; do
  [[ -f $SCRIPT_DIR/$helper ]] || fail "Missing $helper; keep the entire installer folder together."
done
for patch in imx681.patch Kconfig.patch Makefile.patch; do
  [[ -s $SCRIPT_DIR/patches/$patch ]] || fail "Missing patches/$patch; keep the entire installer folder together."
done
# The build script is the single source of the kernel version and suffix.
version= suffix=
while IFS= read -r line; do
  case "$line" in
    KERNEL_VERSION=\"*\") version=${line#KERNEL_VERSION=\"}; version=${version%\"} ;;
    CUSTOM_SUFFIX=\"*\") suffix=${line#CUSTOM_SUFFIX=\"}; suffix=${suffix%\"} ;;
  esac
done < "$SCRIPT_DIR/build-linux-kernel.sh"
[[ $version =~ ^[a-zA-Z0-9_.+-]+$ && $suffix =~ ^[a-zA-Z0-9_.+-]+$ ]] || fail 'Cannot read kernel target from build script.'
target="$version$suffix"
running=$(uname -r)
echo "Detected: $(cat /sys/class/dmi/id/product_name)"
echo "Running kernel: $running; target: $target"
case "$mode" in
  status)
    dkms status || true
    for number in 42 43; do
      if [[ -f /sys/class/video4linux/video$number/name ]]; then
        echo "/dev/video$number: $(cat "/sys/class/video4linux/video$number/name")"
      fi
    done
    systemctl --user --no-pager status surface11-camera-front.service surface11-camera-rear.service || true
    ;;
  undo-cameras) bash "$SCRIPT_DIR/setup-system-cameras.sh" undo ;;
  install|cameras|kernel)
    if [[ $mode == kernel || ( $mode == install && $running != "$target" ) ]]; then
      [[ $running != "$target" ]] || fail 'Boot another kernel before rebuilding the same release.'
      mountpoint -q /efi || fail 'Mount your systemd-boot EFI partition at /efi before building.'
      [[ -d /efi/loader ]] || fail 'The current installer requires systemd-boot at /efi.'
      sudo pacman -S --needed linux-firmware sof-firmware alsa-ucm-conf alsa-utils
      bash "$SCRIPT_DIR/build-linux-kernel.sh"
      echo
      echo "Kernel installed. Reboot and select Linux Surface11 Custom ($target)."
      printf 'Then run the SAME installer again: bash %q install\n' "$SCRIPT_DIR/install-surface11.sh"
      echo 'Camera compatibility setup is still pending until after that reboot.'
      exit 0
    fi
    [[ $running == "$target" ]] || fail "Boot $target first, or run the default install command to build it."
    modinfo imx681 >/dev/null || fail 'The IMX681 sensor module is missing from this custom kernel.'
    echo 'Fully quit camera apps and Discord from its tray menu before continuing.'
    sudo pacman -S --needed linux-firmware sof-firmware alsa-ucm-conf alsa-utils
    bash "$SCRIPT_DIR/setup-system-cameras.sh" install
    bash "$SCRIPT_DIR/setup-system-cameras.sh" check
    echo 'Camera checks passed. Test Surface Front Camera and Surface Rear Camera using normal app launchers.'
    echo 'App behavior, audio, reboot/reopen and image quality still need checking on each machine.'
    ;;
esac
