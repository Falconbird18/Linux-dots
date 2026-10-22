#!/usr/bin/env bash
# Install an official Sonora GitHub release as a native, pacman-managed package.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install-sonora.sh [--tag TAG] [--build-only]

Downloads the latest stable Falconbird18/Sonora release by default.
  --tag TAG      Install a particular GitHub release (for example V1.2.2).
  --build-only   Build the Arch package without installing it or dependencies.
  -h, --help     Show this help.

Run as your normal user. makepkg uses sudo for dependency/package installation.
Rerun to update. Uninstall with: sudo pacman -Rns sonora-bin
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
tag=''
build_only=false
while (($#)); do
    case "$1" in
        --tag)
            (($# >= 2)) || die '--tag requires a release tag'
            tag=$2
            [[ -n $tag ]] || die '--tag requires a nonempty release tag'
            shift 2 ;;
        --build-only) build_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

((EUID != 0)) || die 'Run as your normal user, not root or sudo.'
for tool in pacman makepkg curl python3 bsdtar sha256sum fakeroot; do
    command -v "$tool" >/dev/null || die "Missing $tool. Install prerequisites: sudo pacman -S --needed base-devel curl python libarchive"
done
machine=$(uname -m)
case "$machine" in
    x86_64) deb_arch=amd64 ;;
    aarch64) deb_arch=arm64 ;;
    *) die "Unsupported architecture: $machine" ;;
esac

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sonora-installer
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)
api=https://api.github.com/repos/Falconbird18/Sonora/releases
if [[ -n $tag ]]; then
    encoded_tag=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$tag")
    api+=/tags/$encoded_tag
else
    api+=/latest
fi
curl_options=(--fail --location --retry 3 --connect-timeout 20 --proto '=https' --proto-redir '=https')
printf 'Looking up Sonora release for %s...\n' "$machine"
curl "${curl_options[@]}" --silent --show-error -H 'Accept: application/vnd.github+json' "$api" -o "$work/release.json"

# Validate metadata before using it in shell or PKGBUILD source. Never eval it.
python3 - "$work/release.json" "$deb_arch" > "$work/asset" <<'PY'
import json, re, sys, urllib.parse
release = json.load(open(sys.argv[1]))
assets = [a for a in release.get('assets', [])
          if re.fullmatch(r'Sonora_[0-9][0-9A-Za-z.+~-]*_' + sys.argv[2] + r'\.deb', a['name'], re.I)]
if len(assets) != 1:
    sys.exit(f"Expected one Sonora {sys.argv[2]} .deb asset; found {len(assets)}. This release may not support your architecture.")
asset = assets[0]
digest = asset.get('digest') or ''
if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    sys.exit('Release asset has no GitHub SHA-256 digest; refusing an unverified download.')
url = asset['browser_download_url']
if not url.startswith('https://github.com/Falconbird18/Sonora/releases/download/') or any(c.isspace() for c in url):
    sys.exit('Unexpected release download URL.')
print(url)
print(digest.split(':', 1)[1])
print(release['tag_name'])
print('https://raw.githubusercontent.com/Falconbird18/Sonora/' +
      urllib.parse.quote(release['tag_name'], safe='') + '/LICENSE.md')
PY
mapfile -t asset < "$work/asset"
printf 'Downloading Sonora %s...\n' "${asset[2]}"
curl "${curl_options[@]}" "${asset[0]}" -o "$work/sonora.deb"
printf '%s  %s\n' "${asset[1]}" "$work/sonora.deb" | sha256sum --check
curl "${curl_options[@]}" --silent --show-error "${asset[3]}" -o "$work/LICENSE.md"
license_hash=$(sha256sum "$work/LICENSE.md")
license_hash=${license_hash%% *}

cd "$work"
bsdtar -xf sonora.deb
shopt -s nullglob
control_archives=(control.tar.*)
data_archives=(data.tar.*)
((${#control_archives[@]} == 1 && ${#data_archives[@]} == 1)) || die 'Unexpected Debian package structure'
bsdtar -xOf "${control_archives[0]}" ./control > control
version=$(python3 - "$deb_arch" <<'PY'
import re, sys
fields = dict(line.split(': ', 1) for line in open('control').read().splitlines()
              if ': ' in line and not line.startswith(' '))
if fields.get('Package') != 'sonora' or fields.get('Architecture') != sys.argv[1]:
    sys.exit('Unexpected package name or architecture in downloaded .deb')
version = fields.get('Version', '')
if not re.fullmatch(r'[0-9][0-9A-Za-z.+]*', version):
    sys.exit(f'Unsupported package version: {version!r}')
print(version)
PY
)

cat > PKGBUILD <<EOF
pkgname=sonora-bin
pkgver=$version
pkgrel=1
pkgdesc='Sheet music library and score viewer (official release binary)'
arch=('$machine')
url='https://github.com/Falconbird18/Sonora'
license=('MIT')
depends=('webkit2gtk-4.1' 'gtk3')
provides=("sonora=\$pkgver")
conflicts=('sonora')
options=('!strip' '!debug')
source=('sonora.deb' 'LICENSE.md')
sha256sums=('${asset[1]}' '$license_hash')
EOF
cat >> PKGBUILD <<'EOF'

package() {
    local archives=("$srcdir"/data.tar.*)
    ((${#archives[@]} == 1)) || return 1
    bsdtar -xf "${archives[0]}" -C "$pkgdir"
    test -x "$pkgdir/usr/bin/sonora" || return 1
    install -d "$pkgdir/usr/lib/sonora"
    mv "$pkgdir/usr/bin/sonora" "$pkgdir/usr/lib/sonora/sonora"
    cat > "$pkgdir/usr/bin/sonora" <<'LAUNCHER'
#!/bin/sh
# Let GTK/WebKit render at the compositor's native scale on Wayland.
if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export GDK_BACKEND=wayland
fi
exec /usr/lib/sonora/sonora "$@"
LAUNCHER
    chmod 755 "$pkgdir/usr/bin/sonora"
    install -Dm644 "$srcdir/LICENSE.md" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
EOF

if "$build_only"; then
    PKGDEST="$cache" makepkg --cleanbuild --force
else
    PKGDEST="$cache" makepkg --cleanbuild --force --syncdeps --install
fi
printf '\nSonora %s package saved in %s\n' "$version" "$cache"
if ! "$build_only"; then
    printf 'Installed. Launch Sonora from the app menu or run: sonora\n'
fi
