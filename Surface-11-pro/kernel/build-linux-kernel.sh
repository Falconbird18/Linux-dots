#!/usr/bin/env bash
# Build the pinned Surface kernel; do not overwrite the running kernel modules.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VERSION="7.2.9"
CUSTOM_SUFFIX="-surface11-camera1"
KERNEL_RELEASE="$KERNEL_VERSION$CUSTOM_SUFFIX"
KERNEL_SHA256="b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba"
WORK_DIR="${SURFACE11_BUILD_DIR:-$HOME/surface-kernel-build}"
KERNEL_DIR="$WORK_DIR/linux-$KERNEL_VERSION-camera1"
CAMERA_MODULE_HELPER="$SCRIPT_DIR/ensure-camera-module.sh"
ESP=/efi
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user.'
[[ $(uname -m) == x86_64 && $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] || fail 'Only Intel Surface Pro 11 SKU 2103 is supported.'
[[ $(uname -r) != "$KERNEL_RELEASE" ]] || fail 'Boot another kernel before rebuilding this release.'
mountpoint -q "$ESP" && sudo test -d "$ESP/loader" || fail 'Mount the systemd-boot ESP at /efi.'
command -v dracut >/dev/null || command -v mkinitcpio >/dev/null || fail 'Install dracut or mkinitcpio first.'
sudo pacman -S --needed base-devel git bc pahole cpio libelf ncurses curl tar xz zstd python
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
echo "=== [6/11] Preparing Kernel Configuration ==="
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

scripts/config --enable CONFIG_STAGING
scripts/config --enable CONFIG_VIDEO_INTEL_IPU7
scripts/config --module CONFIG_VIDEO_IMX681
scripts/config --module CONFIG_VIDEO_OV13858
scripts/config --module CONFIG_INTEL_SKL_INT3472
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --disable CONFIG_RUST
scripts/config --set-str CONFIG_LOCALVERSION "$CUSTOM_SUFFIX"

scripts/config --enable CONFIG_SOUNDWIRE
scripts/config --enable CONFIG_SOUNDWIRE_INTEL
scripts/config --enable CONFIG_SND_SOC_SOF_INTEL_LNL
scripts/config --module CONFIG_SND_SOC_RT1320_SDW

make olddefconfig

if ! grep -q '^CONFIG_VIDEO_IMX681=m$' .config ||
   ! grep -q '^CONFIG_VIDEO_OV13858=m$' .config; then
    echo "[-] Both IMX681 and OV13858 must be enabled as modules."
    echo "    Check the driver's Kconfig dependencies and kernel configuration."
    exit 1
fi

echo "[+] IMX681 will be built as a kernel module."

echo "=== [7/11] Incremental compile ==="
echo "[*] Compiling (incremental – only changed objects will be rebuilt)..."
make -j"${SURFACE11_BUILD_JOBS:-$(nproc)}"

echo "=== [8/11] Installing modules ==="
ACTUAL_KERNEL_RELEASE=$(make -s kernelrelease)
[[ $ACTUAL_KERNEL_RELEASE == "$KERNEL_RELEASE" ]] || { echo "Unexpected kernel release: $ACTUAL_KERNEL_RELEASE" >&2; exit 1; }
sudo make modules_install

echo "=== [9/11] Installing kernel image to ESP ($ESP) ==="
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

# Keep the previous custom boot assets recoverable; leave other kernels alone.
BACKUP_DIR="$ESP/surface11-backups/$(date +%Y%m%d-%H%M%S)"
if sudo test -f "$ESP/vmlinuz-linux-surface11-camera1"; then
    sudo mkdir -p "$BACKUP_DIR"
    for file in vmlinuz-linux-surface11-camera1 initramfs-linux-surface11-camera1.img System.map-linux-surface11-camera1 config-linux-surface11-camera1 loader/entries/surface11-camera1.conf; do
        ! sudo test -f "$ESP/$file" || sudo cp -a "$ESP/$file" "$BACKUP_DIR/"
    done
    echo "[+] Previous custom boot assets saved in $BACKUP_DIR"
fi

sudo cp -v arch/x86/boot/bzImage "$ESP/vmlinuz-linux-surface11-camera1"
sudo cp -v System.map           "$ESP/System.map-linux-surface11-camera1"
sudo cp -v .config              "$ESP/config-linux-surface11-camera1"

echo "=== [10/11] Generating initramfs ==="
if command -v dracut &>/dev/null; then
    echo "[*] Using dracut..."
    sudo dracut --force "$ESP/initramfs-linux-surface11-camera1.img" "$ACTUAL_KERNEL_RELEASE"
elif command -v mkinitcpio &>/dev/null; then
    echo "[*] Using mkinitcpio..."
    sudo mkinitcpio -k "$ACTUAL_KERNEL_RELEASE" -g "$ESP/initramfs-linux-surface11-camera1.img"
else
    echo "[-] Neither dracut nor mkinitcpio found."
    exit 1
fi

echo "=== [11/11] Creating systemd-boot entry ==="
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

ENTRY_FILE="$ESP/loader/entries/surface11-camera1.conf"

sudo tee "$ENTRY_FILE" > /dev/null <<EOF
title   Linux Surface11 Cameras ($KERNEL_RELEASE)
linux   /vmlinuz-linux-surface11-camera1
initrd  /initramfs-linux-surface11-camera1.img
options $BOOT_OPTIONS
EOF

echo
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo
echo "Kernel:     $ESP/vmlinuz-linux-surface11-camera1"
echo "Initramfs:  $ESP/initramfs-linux-surface11-camera1.img"
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
