#!/usr/bin/env bash
# Build the pinned Surface kernel; do not overwrite the running kernel modules.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/version.env"
KERNEL_RELEASE="$KERNEL_VERSION$CUSTOM_SUFFIX"
BOOT_STEM="linux-$KERNEL_RELEASE"
ENTRY_NAME="$KERNEL_RELEASE.conf"
# Reuse the installed source location; moving it would break DKMS's build link.
installed_build=$(readlink -f "/usr/lib/modules/$KERNEL_RELEASE/build" 2>/dev/null || true)
if [[ -z ${SURFACE11_BUILD_DIR:-} && -d $installed_build &&
      ${installed_build##*/} == "linux-$KERNEL_VERSION-camera1" ]]; then
    WORK_DIR="${installed_build%/*}"
else
    WORK_DIR="${SURFACE11_BUILD_DIR:-$HOME/surface-kernel-build}"
fi
KERNEL_DIR="$WORK_DIR/linux-$KERNEL_VERSION-camera1"
CAMERA_MODULE_HELPER="$SCRIPT_DIR/ensure-camera-module.sh"
ESP=/efi
fail() { echo "ERROR: $*" >&2; exit 1; }
mode=${1:-install}
[[ $# -le 1 && ( $mode == install || $mode == build ) ]] || fail 'Usage: build-linux-kernel.sh [install|build]'
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user.'
[[ $(uname -m) == x86_64 && $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] || fail 'Only Intel Surface Pro 11 SKU 2103 is supported.'
[[ $(uname -r) != "$KERNEL_RELEASE" ]] || fail 'Boot another kernel before rebuilding this release.'
if [[ $mode == install ]]; then
  mountpoint -q "$ESP" && sudo test -d "$ESP/loader" || fail 'Mount the systemd-boot ESP at /efi.'
  command -v dracut >/dev/null || command -v mkinitcpio >/dev/null || fail 'Install dracut or mkinitcpio first.'
  sudo pacman -S --needed base-devel git bc pahole cpio libelf ncurses curl tar xz zstd python
fi
mkdir -p "$WORK_DIR"
archive="$WORK_DIR/linux-$KERNEL_VERSION.tar.xz"
if [[ ! -f $archive ]]; then
  curl --fail --location --retry 3 "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-$KERNEL_VERSION.tar.xz" -o "$archive.download"
  printf '%s  %s\n' "$KERNEL_SHA256" "$archive.download" | sha256sum --check --status || fail 'Kernel source checksum mismatch.'
  mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$KERNEL_SHA256" "$archive" | sha256sum --check --status || fail 'Kernel source checksum mismatch.'
if [[ ! -d $KERNEL_DIR ]]; then
  mkdir -p "$KERNEL_DIR"
  tar -xf "$archive" --strip-components=1 -C "$KERNEL_DIR"
fi
bash "$SCRIPT_DIR/apply-kernel-patches.sh" "$KERNEL_DIR"
cd "$KERNEL_DIR"
echo "Preparing kernel configuration"
if [ -f .config ]; then
    echo "[+] Existing .config found, keeping current configuration."
elif [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > .config
    echo "[+] Loaded running kernel config from /proc/config.gz"
elif [[ -f /usr/lib/modules/$(uname -r)/build/.config ]]; then
    cp "/usr/lib/modules/$(uname -r)/build/.config" .config
else
    fail "No running kernel configuration found; supply a working .config in $KERNEL_DIR."
fi

# Apply only our explicit overrides; leave the base driver configuration intact.
while IFS='=' read -r symbol value; do
    [[ -n $symbol && $symbol != \#* ]] || continue
    case "$value" in
        y) scripts/config --enable "$symbol" ;;
        m) scripts/config --module "$symbol" ;;
        n) scripts/config --disable "$symbol" ;;
        '"@CUSTOM_SUFFIX@"') scripts/config --set-str "$symbol" "$CUSTOM_SUFFIX" ;;
        *) fail "Invalid Surface kernel override: $symbol=$value" ;;
    esac
done < "$SCRIPT_DIR/surface11.config"

make olddefconfig

grep -q '^CONFIG_BT_INTEL_PCIE=m$' .config || fail 'Intel PCIe Bluetooth driver was not enabled.'

if ! grep -q '^CONFIG_VIDEO_IMX681=m$' .config ||
   ! grep -q '^CONFIG_VIDEO_OV13858=m$' .config; then
    echo "[-] Both IMX681 and OV13858 must be enabled as modules."
    echo "    Check the driver's Kconfig dependencies and kernel configuration."
    exit 1
fi

echo "[+] IMX681 will be built as a kernel module."

echo "Building kernel (incremental)"
echo "[*] Compiling (incremental – only changed objects will be rebuilt)..."
make -j"${SURFACE11_BUILD_JOBS:-$(nproc)}"

ACTUAL_KERNEL_RELEASE=$(make -s kernelrelease)
[[ $ACTUAL_KERNEL_RELEASE == "$KERNEL_RELEASE" ]] || { echo "Unexpected kernel release: $ACTUAL_KERNEL_RELEASE" >&2; exit 1; }
if [[ $mode == build ]]; then
  echo "Built $ACTUAL_KERNEL_RELEASE in $KERNEL_DIR. Run the kernel command with the same SURFACE11_BUILD_DIR to install."
  exit 0
fi

echo "Installing modules"
sudo make modules_install

echo "Installing kernel image to ESP ($ESP)"
ACTUAL_KERNEL_RELEASE=$(make -s kernelrelease)
echo "[*] Actual kernelrelease: $ACTUAL_KERNEL_RELEASE"

# Keep the standard-camera bridge available after a custom kernel rebuild.
# This builds an external module; it does not patch the kernel source.
if [[ -f /etc/modules-load.d/surface11-camera.conf ]]; then
    command -v dkms >/dev/null || { echo "[-] Camera bridge requires DKMS."; exit 1; }
    bash "$CAMERA_MODULE_HELPER" "$ACTUAL_KERNEL_RELEASE" rebuild
fi

# Make sure ESP is accessible
if ! mountpoint -q "$ESP"; then
    echo "[-] ESP directory $ESP does not exist or is not mounted!"
    exit 1
fi

# Version each release so the working custom entry remains a bootable fallback.
# Back up this release only when reinstalling it; leave other kernels alone.
BACKUP_DIR="$ESP/surface11-backups/$(date +%Y%m%d-%H%M%S)"
if sudo test -f "$ESP/vmlinuz-$BOOT_STEM"; then
    sudo mkdir -p "$BACKUP_DIR"
    for file in "vmlinuz-$BOOT_STEM" "initramfs-$BOOT_STEM.img" "System.map-$BOOT_STEM" "config-$BOOT_STEM" "loader/entries/$ENTRY_NAME"; do
        ! sudo test -f "$ESP/$file" || sudo cp -a "$ESP/$file" "$BACKUP_DIR/"
    done
    echo "[+] Previous custom boot assets saved in $BACKUP_DIR"
fi

sudo cp -v arch/x86/boot/bzImage "$ESP/vmlinuz-$BOOT_STEM"
sudo cp -v System.map           "$ESP/System.map-$BOOT_STEM"
sudo cp -v .config              "$ESP/config-$BOOT_STEM"

echo "Generating initramfs"
if command -v dracut &>/dev/null; then
    echo "[*] Using dracut..."
    sudo dracut --force "$ESP/initramfs-$BOOT_STEM.img" "$ACTUAL_KERNEL_RELEASE"
elif command -v mkinitcpio &>/dev/null; then
    echo "[*] Using mkinitcpio..."
    sudo mkinitcpio -k "$ACTUAL_KERNEL_RELEASE" -g "$ESP/initramfs-$BOOT_STEM.img"
else
    echo "[-] Neither dracut nor mkinitcpio found."
    exit 1
fi

echo "Creating systemd-boot entry"
sudo mkdir -p "$ESP/loader/entries"

BOOT_OPTIONS=$(python3 - <<'PYOPTS'
from pathlib import Path
import shlex
args = [x for x in shlex.split(Path('/proc/cmdline').read_text())
        if not x.startswith(('BOOT_IMAGE=', 'initrd='))]
if not any(x.startswith('root=') for x in args):
    raise SystemExit('No root= boot option found; refusing to invent a boot configuration.')
print(' '.join('"' + x.replace('"', '\\"') + '"' if any(c.isspace() for c in x) else x for x in args))
PYOPTS
)

ENTRY_FILE="$ESP/loader/entries/$ENTRY_NAME"

sudo tee "$ENTRY_FILE" > /dev/null <<EOF
title   Linux Surface11 Cameras ($KERNEL_RELEASE)
linux   /vmlinuz-$BOOT_STEM
initrd  /initramfs-$BOOT_STEM.img
options $BOOT_OPTIONS
EOF

echo
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo
echo "Kernel:     $ESP/vmlinuz-$BOOT_STEM"
echo "Initramfs:  $ESP/initramfs-$BOOT_STEM.img"
echo "Modules:    /lib/modules/$ACTUAL_KERNEL_RELEASE"
echo "Boot entry: $ENTRY_FILE"
echo
echo "Entry contents:"
sudo cat "$ENTRY_FILE"
echo
echo "Reboot into Linux Surface11 Cameras ($KERNEL_RELEASE), then rerun install-surface11.sh."
echo
echo "After booting into it, verify with:"
echo "  aplay -l"
echo "  ls /sys/bus/soundwire/devices/"
echo "  dmesg | grep -iE 'soundwire|rt1320|sof'"
