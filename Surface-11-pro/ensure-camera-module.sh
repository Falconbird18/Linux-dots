#!/usr/bin/env bash
# Build an isolated DKMS variant; never edit the package-owned driver source.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
kernel="${1:-$(uname -r)}"
mode="${2:-check}"
version=0.15.4.surface11.1
source_dir="/usr/src/v4l2loopback-$version"
base_dir=/usr/src/v4l2loopback-0.15.4
patch_file="$SCRIPT_DIR/patches/v4l2loopback-capture-queue.patch"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $mode == check || $mode == rebuild ]] || fail 'Expected check or rebuild mode.'
[[ -f /usr/lib/modules/$kernel/build/Module.symvers ]] || fail "Missing configured build tree for $kernel."
[[ -f $base_dir/v4l2loopback.c ]] || fail 'The capture-queue fix requires v4l2loopback-dkms 0.15.4.'
printf '%s  %s\n' a3e78c9ee061e5ce81b0ea45bb1730ce531b5ece7194f56a47d831ec2d009c2b "$base_dir/v4l2loopback.c" |
  sha256sum --check --status || fail 'Unexpected v4l2loopback source; refusing an unverified kernel-module patch.'
identity=$(sha256sum "$patch_file" "$SCRIPT_DIR/ensure-camera-module.sh" "$base_dir/v4l2loopback.h" "$base_dir/v4l2loopback_formats.h")
changed=0
if [[ -d $source_dir && ! -f $source_dir/managed-by-surface11-camera ]]; then
  fail "Refusing to overwrite unmanaged source: $source_dir"
fi
if [[ ! -f $source_dir/managed-by-surface11-camera ]] ||
   [[ $(cat "$source_dir/managed-by-surface11-camera") != "$identity" ]]; then
  staging=$(mktemp -d)
  trap 'rm -rf "$staging"' EXIT
  for file in Makefile Kbuild v4l2loopback.c v4l2loopback.h v4l2loopback_formats.h; do
    cp "$base_dir/$file" "$staging/"
  done
  patch -d "$staging" -p1 < "$patch_file"
  cat > "$staging/dkms.conf" <<CONFIG
PACKAGE_NAME="v4l2loopback"
PACKAGE_VERSION="$version"
MAKE[0]='make KERNEL_DIR=\${kernel_source_dir} v4l2loopback'
CLEAN=true
BUILT_MODULE_NAME[0]="v4l2loopback"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
CONFIG
  printf '%s\n' "$identity" > "$staging/managed-by-surface11-camera"
  sudo install -d "$source_dir"
  sudo install -m 644 "$staging/"* "$source_dir/"
  changed=1
fi
if ! dkms status -m v4l2loopback -v "$version" | rg -q '^v4l2loopback/'; then
  sudo dkms add -m v4l2loopback -v "$version"
fi
shopt -s nullglob
built=(/var/lib/dkms/v4l2loopback/"$version"/"$kernel"/"$(uname -m)"/module/v4l2loopback.ko*)
if (( changed )) || [[ $mode == rebuild || ${#built[@]} == 0 ]]; then
  sudo dkms build --force -m v4l2loopback -v "$version" -k "$kernel"
fi
built=(/var/lib/dkms/v4l2loopback/"$version"/"$kernel"/"$(uname -m)"/module/v4l2loopback.ko*)
[[ ${#built[@]} == 1 ]] || fail 'Expected exactly one built loopback module (possibly compressed).'
expected=$(modinfo -F srcversion "${built[0]}")
if [[ $(modinfo -k "$kernel" -F srcversion v4l2loopback 2>/dev/null || true) != "$expected" ]]; then
  sudo dkms install --force -m v4l2loopback -v "$version" -k "$kernel"
fi
sudo depmod -a "$kernel"
[[ $(modinfo -k "$kernel" -F srcversion v4l2loopback) == "$expected" ]] || fail 'Patched loopback module is not the indexed module.'
echo "Verified capture-queue-fixed v4l2loopback for $kernel ($expected)."
