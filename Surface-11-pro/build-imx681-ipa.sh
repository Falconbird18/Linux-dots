#!/usr/bin/env bash
# Managed by surface11-camera. Build a matched IPA sidecar; keep distro libraries.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cache=${1:?Expected an absolute build/cache directory}
version=0.7.2
archive_sha=64881a4bafbda02f34861153d8f0d42be9ff46f5598408f9b585b07a10c448c9
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $cache == /* && $cache != / ]] || fail 'Expected a dedicated absolute cache path.'
[[ $(pkg-config --modversion libcamera) == "$version" ]] ||
  fail "The IMX681 IPA helper currently supports libcamera $version only; do not load it into another version."
mkdir -p "$cache"
identity="$(pacman -Q libcamera libcamera-ipa)
$(sha256sum "$SCRIPT_DIR/patches/libcamera-imx681-helper.patch" "$SCRIPT_DIR/tests/test-imx681-gain.cpp" "$SCRIPT_DIR/build-imx681-ipa.sh")"
if [[ -s $cache/ipa/ipa_soft_simple.so && -f $cache/build-identity ]] &&
   [[ $(cat "$cache/build-identity") == "$identity" ]]; then
  echo 'Verified cached IMX681 IPA build for the installed libcamera packages.'
  exit 0
fi
archive="$cache/libcamera-v$version.tar.gz"
if [[ ! -f $archive ]] || [[ $(sha256sum "$archive" | cut -d' ' -f1) != "$archive_sha" ]]; then
  curl --fail --location --retry 3 \
    "https://gitlab.freedesktop.org/camera/libcamera/-/archive/v$version/libcamera-v$version.tar.gz" -o "$archive.download"
  [[ $(sha256sum "$archive.download" | cut -d' ' -f1) == "$archive_sha" ]] || fail 'libcamera source checksum mismatch.'
  mv "$archive.download" "$archive"
fi
source_dir="$cache/source"
build_dir="$cache/build"
# These three directories are generated exclusively by this builder.
rm -rf -- "$source_dir" "$build_dir" "$cache/stage"
mkdir -p "$source_dir"
tar --extract --gzip --file="$archive" --directory="$source_dir" --strip-components=1
patch --directory="$source_dir" --strip=1 --forward < "$SCRIPT_DIR/patches/libcamera-imx681-helper.patch"
python3 - "$source_dir/src/ipa/simple/meson.build" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
old = 'install_dir : ipa_install_dir)'
if s.count(old) != 1:
    raise SystemExit('Unexpected IPA install definition')
p.write_text(s.replace(old, "install_dir : ipa_install_dir, install_tag : 'surface11-ipa')"))
PY
meson setup "$build_dir" "$source_dir" --prefix=/usr --libdir=lib --buildtype=release \
  -Dpipelines=simple -Dipas=simple -Dcam=disabled -Dqcam=disabled \
  -Dgstreamer=disabled -Dv4l2=disabled -Dpycamera=disabled -Dlc-compliance=disabled \
  -Ddocumentation=disabled -Dtest=false -Dtracing=disabled -Dsoftisp-gpu=disabled
jobs=$(nproc)
(( jobs <= 4 )) || jobs=4
ninja -C "$build_dir" -j "$jobs" src/ipa/simple/ipa_soft_simple.so
read -r -a base_libs <<< "$(pkg-config --libs libcamera-base)"
c++ -std=c++17 -DLIBCAMERA_BASE_PRIVATE -I"$source_dir/include" -I"$build_dir/include" -I"$source_dir/src/ipa" \
  -include "$build_dir/config.h" "$SCRIPT_DIR/tests/test-imx681-gain.cpp" \
  "$source_dir/src/ipa/libipa/camera_sensor_helper.cpp" "${base_libs[@]}" -o "$cache/test-imx681-gain"
"$cache/test-imx681-gain"
# Stage only the IPA module, stripping its build-tree runtime library paths.
meson install -C "$build_dir" --no-rebuild --tags surface11-ipa --destdir "$cache/stage"
mkdir -p "$cache/ipa"
install -m 755 "$cache/stage/usr/lib/libcamera/ipa/ipa_soft_simple.so" "$cache/ipa/ipa_soft_simple.so"
python3 - "$cache/ipa/ipa_soft_simple.so" <<'PY'
import ctypes
import sys
ctypes.CDLL(sys.argv[1])
PY
pacman -Q libcamera libcamera-ipa > "$cache/packages.txt"
printf '%s\n' "$identity" > "$cache/build-identity"
echo 'PASS: IMX681 gain helper and module linkage verified against installed libcamera.'
