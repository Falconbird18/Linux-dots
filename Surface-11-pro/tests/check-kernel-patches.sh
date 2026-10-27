#!/usr/bin/env bash
# Check fresh-source application and idempotence using the pinned source archive.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
archive=${1:?Usage: check-kernel-patches.sh /path/to/linux-7.2.9.tar.xz}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
printf '%s  %s\n' b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba "$archive" | sha256sum --check --status
tar -xf "$archive" --strip-components=1 -C "$build" \
  linux-7.2.9/Makefile linux-7.2.9/drivers/media/i2c/Kconfig \
  linux-7.2.9/drivers/media/i2c/Makefile linux-7.2.9/drivers/media/i2c/ov13858.c \
  linux-7.2.9/drivers/media/pci/intel/ipu-bridge.c \
  linux-7.2.9/include/linux/platform_data/x86/int3472.h \
  linux-7.2.9/drivers/platform/x86/intel/int3472/discrete.c \
  linux-7.2.9/drivers/soundwire/dmi-quirks.c
bash "$ROOT/apply-kernel-patches.sh" "$build"
bash "$ROOT/apply-kernel-patches.sh" "$build"
if rg '=3D|v4l2_subdev_client_info' "$build/drivers/media/i2c/imx681.c"; then
  echo 'Invalid IMX681 source' >&2; exit 1
fi
echo 'PASS: complete kernel series applies to pristine 7.2.9 and verifies on repeat'
