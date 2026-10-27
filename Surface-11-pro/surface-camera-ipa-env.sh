#!/usr/bin/env bash
# Managed by surface11-camera. Never load a private IPA across package versions.
set -euo pipefail
ipa_dir=${1:?Expected IPA directory}
env_file=${2:?Expected environment file}
mkdir -p "$(dirname "$env_file")"
temporary=$(mktemp "$env_file.XXXXXX")
trap 'rm -f "$temporary"' EXIT
printf 'LIBCAMERA_IPA_MODULE_PATH=\n' > "$temporary"
if [[ -s $ipa_dir/ipa_soft_simple.so && -f $ipa_dir/packages.txt ]] &&
   current=$(pacman -Q libcamera libcamera-ipa) &&
   [[ $current == "$(cat "$ipa_dir/packages.txt")" ]]; then
  # EnvironmentFile syntax supports quoted values. Escape path metacharacters.
  path=${ipa_dir//\\/\\\\}
  path=${path//\"/\\\"}
  printf 'LIBCAMERA_IPA_MODULE_PATH="%s"\n' "$path" > "$temporary"
else
  echo 'Surface IMX681 IPA is absent or packages changed; using distro IPA. Rerun the camera installer to refresh the helper.' >&2
fi
mv "$temporary" "$env_file"
