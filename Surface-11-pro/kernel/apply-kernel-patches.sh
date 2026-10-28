#!/usr/bin/env bash
# Apply the complete, ordered patch series, without downloads or source guessing.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir=${1:?Usage: apply-kernel-patches.sh KERNEL_SOURCE}
cd "$source_dir"
[[ -f Makefile && -d drivers/media/i2c ]] || { echo 'Not a kernel source tree' >&2; exit 1; }
while IFS= read -r name; do
  [[ -n $name && $name != \#* ]] || continue
  [[ $name != */* && -s $SCRIPT_DIR/../patches/$name ]] || exit 1
  patch_file="$SCRIPT_DIR/../patches/$name"
  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file"
    echo "Applied $name"
  elif git apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "Already applied: $name"
  else
    echo "Cannot apply or verify $name. Use a fresh pinned kernel tree; partial/unknown changes are not accepted." >&2
    exit 1
  fi
done < "$SCRIPT_DIR/../patches/series"
