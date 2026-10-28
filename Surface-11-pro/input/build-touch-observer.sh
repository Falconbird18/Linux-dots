#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output=${1:?Expected plugin output path}
mkdir -p "$(dirname -- "$output")"
# Always replace the inode atomically: never truncate a library loaded by Hyprland.
temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
read -r -a flags <<< "$(pkg-config --cflags hyprland)"
c++ -std=c++23 -O2 -shared -fPIC "${flags[@]}" "$SCRIPT_DIR/touch-observer.cpp" -o "$temporary"
chmod 755 "$temporary"
mv -f -- "$temporary" "$output"
