#!/usr/bin/env bash
# Single entry point for the currently supported Intel Surface Pro 11 fixes.
# Run as the logged-in desktop user; individual privileged steps request sudo.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: bash install-surface11.sh [install|status|cameras|camera-policy|quality|camera-quality|bluetooth|kernel|kernel-build|verify-boot|rotation|touch|undo-cameras]
  install       Default: repair Bluetooth/tablet setup; build kernel or cameras.
  status        Show hardware, kernel, Bluetooth, camera and tablet services.
  cameras       Install/repair standard webcams on the patched custom kernel.
  camera-policy Repair duplicate IPU7 camera listings without rebuilding.
  bluetooth     Install/repair Intel PCIe Bluetooth and enable BlueZ at boot.
  rotation      Install/repair smooth Hyprland auto-rotation independently.
  touch         Install/repair tablet keyboard and touchscreen navigation.
  camera-quality [natural|balanced|detail]
                Update only image processing, with live checks and rollback.
  quality       Measure exposure stability/clipping on both shared app routes.
  kernel        Build/install the patched kernel while booted into another kernel.
  kernel-build  Build only, using existing dependencies; no privileged changes.
  verify-boot   Read-only checks of installed boot files; requires sudo.
  undo-cameras  Remove the webcam bridge, keeping kernel drivers and packages.

Supports only Intel Surface Pro 11 for Business SKU 2103 on Arch-based Linux.
Keep the entire Surface-11-pro folder, including patches/ and helper scripts.
A kernel change requires a reboot: select the custom kernel, then run this same
command again. It will continue with the camera setup. Never automatically reboots.
HELP
}
mode=${1:-install}
case "$mode" in -h|--help|help) usage; exit 0;; esac
[[ $# -le 1 || ( $mode == camera-quality && $# == 2 ) ]] || fail 'See --help for command arguments.'
case "$mode" in install|status|cameras|camera-policy|quality|camera-quality|bluetooth|kernel|kernel-build|verify-boot|rotation|touch|undo-cameras) ;; *) usage >&2; exit 2;; esac
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user, not with sudo before the whole command.'
[[ $(uname -m) == x86_64 ]] || fail 'This is the Intel installer; Snapdragon/ARM models are unsupported.'
vendor=$(cat /sys/class/dmi/id/sys_vendor)
sku=$(cat /sys/class/dmi/id/product_sku)
[[ $vendor == 'Microsoft Corporation' && $sku == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] ||
  fail "Unsupported hardware: $vendor / $sku. Model-specific patches will not be applied."
command -v pacman >/dev/null || fail 'This installer currently supports Arch-based distributions only.'
command -v systemctl >/dev/null || fail 'systemd is required.'
for helper in \
  camera/set-camera-quality.sh \
  kernel/surface11.config \
  kernel/version.env \
  kernel/verify-boot.sh \
  bluetooth/setup-bluetooth.sh \
  input/build-touch-observer.sh \
  input/touch-observer.cpp \
  input/touch-effects.py \
  input/touch-effects.qml \
  input/setup-touch.sh \
  input/surface11-touch.py \
  input/touch.lua \
  input/setup-autorotation.sh \
  input/81-surface11-accelerometer.rules \
  input/surface11-autorotate.py \
  kernel/build-linux-kernel.sh \
  kernel/apply-kernel-patches.sh \
  kernel/ensure-camera-module.sh \
  camera/setup-system-cameras.sh \
  camera/surface-camera-relay.sh \
  camera/publish-surface-camera.sh \
  camera/check-camera-routing.py \
  camera/check-camera-quality.py \
  camera/build-imx681-ipa.sh \
  camera/surface-camera-ipa-env.sh \
  camera/surface-camera-publisher.c \
  camera/reprobe-front-sensor.sh \
  camera/surface-camera-relay.c \
  camera/check-shared-camera.py \
  camera/loopback-writer.h \
  tests/check-v4l2-buffers.c \
  patches/v4l2loopback-capture-queue.patch \
; do
  [[ -f $SCRIPT_DIR/$helper ]] || fail "Missing $helper; keep the entire installer folder together."
done
while IFS= read -r patch; do
  [[ -s $SCRIPT_DIR/patches/$patch ]] || fail "Missing patches/$patch; keep the entire installer folder together."
done < "$SCRIPT_DIR/patches/series"
# The source pin is shared by builds and validation.
source "$SCRIPT_DIR/kernel/version.env"
target="$KERNEL_VERSION$CUSTOM_SUFFIX"
running=$(uname -r)
echo "Detected: $(cat /sys/class/dmi/id/product_name)"
echo "Running kernel: $running; target: $target"
case "$mode" in
  status)
    echo "Installed target build tree: $(readlink -f "/usr/lib/modules/$target/build" 2>/dev/null || true)"
    echo 'Keep that directory: DKMS uses it for the camera module.'
    bash "$SCRIPT_DIR/bluetooth/setup-bluetooth.sh" check || true
    dkms status || true
    for number in 42 43; do
      if [[ -f /sys/class/video4linux/video$number/name ]]; then
        echo "/dev/video$number: $(cat "/sys/class/video4linux/video$number/name")"
      fi
    done
    systemctl --user --no-pager status surface11-cameras.service surface11-autorotate.service surface11-touch.service || true
    ;;
  bluetooth) bash "$SCRIPT_DIR/bluetooth/setup-bluetooth.sh" install ;;
  camera-policy) bash "$SCRIPT_DIR/camera/setup-system-cameras.sh" policy ;;
  kernel-build) bash "$SCRIPT_DIR/kernel/build-linux-kernel.sh" build ;;
  verify-boot) sudo bash "$SCRIPT_DIR/kernel/verify-boot.sh" ;;
  touch) bash "$SCRIPT_DIR/input/setup-touch.sh" install ;;
  rotation) bash "$SCRIPT_DIR/input/setup-autorotation.sh" install ;;
  camera-quality) bash "$SCRIPT_DIR/camera/set-camera-quality.sh" "${2:-natural}" ;;
  quality) bash "$SCRIPT_DIR/camera/setup-system-cameras.sh" quality ;;
  undo-cameras) bash "$SCRIPT_DIR/camera/setup-system-cameras.sh" undo ;;
  install|cameras|kernel)
    if [[ $mode == install ]]; then
      bash "$SCRIPT_DIR/bluetooth/setup-bluetooth.sh" install
      bash "$SCRIPT_DIR/input/setup-autorotation.sh" install
      bash "$SCRIPT_DIR/input/setup-touch.sh" install
    fi
    if [[ $mode == kernel || ( $mode == install && $running != "$target" ) ]]; then
      [[ $running != "$target" ]] || fail 'Boot another kernel before rebuilding the same release.'
      mountpoint -q /efi || fail 'Mount your systemd-boot EFI partition at /efi before building.'
      sudo test -d /efi/loader || fail 'The current installer requires systemd-boot at /efi.'
      sudo pacman -S --needed linux-firmware sof-firmware alsa-ucm-conf alsa-utils
      bash "$SCRIPT_DIR/kernel/build-linux-kernel.sh"
      echo
      echo "Kernel installed. Reboot and select Linux Surface11 Cameras ($target)."
      printf 'Then run the SAME installer again: bash %q install\n' "$SCRIPT_DIR/install-surface11.sh"
      echo 'Camera compatibility setup is still pending until after that reboot.'
      exit 0
    fi
    [[ $running == *-surface11-camera1 ]] || fail "Boot a Surface11 camera kernel first, or run install to build $target."
    modinfo imx681 >/dev/null || fail 'The IMX681 sensor module is missing from this custom kernel.'
    echo 'Fully quit camera apps and Discord from its tray menu before continuing.'
    sudo pacman -S --needed linux-firmware sof-firmware alsa-ucm-conf alsa-utils
    bash "$SCRIPT_DIR/camera/setup-system-cameras.sh" install
    bash "$SCRIPT_DIR/camera/setup-system-cameras.sh" check
    echo 'Camera checks passed. Test Surface Front Camera and Surface Rear Camera using normal app launchers.'
    echo 'App behavior, audio, reboot/reopen and image quality still need checking on each machine.'
    ;;
esac
