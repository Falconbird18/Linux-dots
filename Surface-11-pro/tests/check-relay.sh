#!/usr/bin/env bash
# No cameras, sudo, or system configuration changes required.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
for script in "$ROOT"/*.sh; do bash -n "$script"; done
for profile in balanced detail; do
  for camera in front rear; do
    SURFACE11_CAMERA_QUALITY=$profile bash "$ROOT/surface-camera-relay.sh" "$camera" --validate
  done
done
read -r -a cflags <<< "$(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)"
read -r -a libs <<< "$(pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)"
cc -Wall -Wextra -Wno-unused-parameter "${cflags[@]}" "$ROOT/tests/test-loopback-writer.c" \
  -o "$build/test-loopback-writer" "${libs[@]}"
"$build/test-loopback-writer"

python3 "$ROOT/tests/check-routing.py"

python3 "$ROOT/tests/check-quality.py"

python3 "$ROOT/tests/check-ipa-env.py"

python3 "$ROOT/tests/check-relay-lifecycle.py"
