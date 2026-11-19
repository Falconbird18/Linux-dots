#!/usr/bin/env bash
# Check fresh-source application and idempotence using the pinned source archive.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/kernel/version.env"
archive=${1:?Usage: check-kernel-patches.sh /path/to/linux-7.3.2.tar.xz}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
printf '%s  %s\n' "$KERNEL_SHA256" "$archive" | sha256sum --check --status
tar -xf "$archive" --strip-components=1 -C "$build" \
  "linux-$KERNEL_VERSION"/Makefile "linux-$KERNEL_VERSION"/drivers/media/i2c/Kconfig \
  "linux-$KERNEL_VERSION"/drivers/media/i2c/Makefile "linux-$KERNEL_VERSION"/drivers/media/i2c/ov13858.c \
  "linux-$KERNEL_VERSION"/drivers/media/pci/intel/ipu-bridge.c \
  "linux-$KERNEL_VERSION"/include/linux/platform_data/x86/int3472.h \
  "linux-$KERNEL_VERSION"/drivers/platform/x86/intel/int3472/discrete.c \
  "linux-$KERNEL_VERSION"/drivers/soundwire/dmi-quirks.c
bash "$ROOT/kernel/apply-kernel-patches.sh" "$build"
bash "$ROOT/kernel/apply-kernel-patches.sh" "$build"
if rg '=3D|v4l2_subdev_client_info' "$build/drivers/media/i2c/imx681.c"; then
  echo 'Invalid IMX681 source' >&2; exit 1
fi
echo "PASS: complete kernel series applies to pristine $KERNEL_VERSION and verifies on repeat"
