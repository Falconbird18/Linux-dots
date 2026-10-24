#!/usr/bin/env bash
# Install the official VST-enabled build alongside the distro package.
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tag=${1:-v4.7.5}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Usage: ./install-musescore.sh [vMAJOR.MINOR.PATCH]' >&2; exit 2; }
(( EUID != 0 )) || { echo 'Run as your normal user.' >&2; exit 1; }
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
base=${XDG_DATA_HOME:-$HOME/.local/share}/musescore-official
[[ $base == /* ]] || { echo 'Expected an absolute data directory.' >&2; exit 1; }
target=$base/$tag-$arch
if [[ ! -x $target/AppRun ]]; then
    for tool in curl python3 sha256sum; do command -v "$tool" >/dev/null; done
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    opts=(--fail --location --retry 3 --connect-timeout 20 --proto '=https' --proto-redir '=https')
    echo "Looking up official MuseScore $tag..."
    curl "${opts[@]}" --silent --show-error "https://api.github.com/repos/musescore/MuseScore/releases/tags/$tag" -o "$work/release.json"
    python3 - "$work/release.json" "$arch" > "$work/asset" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
assets = [a for a in release.get('assets', []) if a['name'].endswith('-' + sys.argv[2] + '.AppImage')]
if len(assets) != 1:
    sys.exit('Expected one official AppImage for this architecture')
a = assets[0]
url = a['browser_download_url']
if not url.startswith('https://github.com/musescore/MuseScore/releases/download/') or any(c.isspace() for c in url):
    sys.exit('Unexpected AppImage URL')
digest = a.get('digest') or ''
if not re.fullmatch('sha256:[0-9a-f]{64}', digest):
    sys.exit('Missing SHA-256 digest; refusing unverified download')
print(url)
print(digest[7:])
PY
    mapfile -t asset < "$work/asset"
    curl "${opts[@]}" "${asset[0]}" -o "$work/MuseScore.AppImage"
    # Pin the default release bytes, independently of mutable API metadata.
    if [[ $tag == v4.7.5 ]]; then
        case "$arch" in
            x86_64) pinned=a31b2da2dbcc2191bcc98beb7be5c15f2f517bedb3444def96fe3088b74d3a1e ;;
            aarch64) pinned=034f0257fd21ed6b7d4863714dbf8e97cc86d454beb79aaa845a5ade3ff99e36 ;;
        esac
        [[ ${asset[1]} == "$pinned" ]] || { echo 'Release checksum differs from pinned checksum.' >&2; exit 1; }
    fi
    printf '%s  %s\n' "${asset[1]}" "$work/MuseScore.AppImage" | sha256sum --check
    chmod +x "$work/MuseScore.AppImage"
    # Extraction avoids a dependency on FUSE for AppImage execution.
    (cd "$work" && ./MuseScore.AppImage --appimage-extract > /dev/null)
    test -x "$work/squashfs-root/AppRun"
    mkdir -p -- "$base"
    if [[ -e $target || -L $target ]]; then
        echo "Incomplete installation exists at $target; move it aside and retry." >&2
        exit 1
    fi
    mv -- "$work/squashfs-root" "$target"
fi
if [[ -e $base/current && ! -L $base/current ]]; then
    echo "Refusing to replace a non-symlink: $base/current" >&2
    exit 1
fi
ln -sfn -- "$tag-$arch" "$base/current"
echo "Official MuseScore installed: $target"
echo "Run $REPO_DIR/install.sh to install the launcher, then reopen MuseScore."
