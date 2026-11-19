#!/usr/bin/env bash
# Targeted userspace processing update; retain a working-camera rollback.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "ERROR: $*" >&2; exit 1; }
profile=${1:-natural}
[[ $# -le 1 ]] || fail 'Usage: set-camera-quality.sh [natural|balanced|detail]'
case "$profile" in natural|balanced|detail) ;; *) fail 'Choose natural, balanced or detail.' ;; esac
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user.'
[[ $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] || fail 'Unsupported Surface model.'
libexec=/usr/local/libexec/surface11-camera
installed="$libexec/surface-camera-relay.sh"
override="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/surface11-cameras.service.d/80-surface11-quality.conf"
state="${XDG_STATE_HOME:-$HOME/.local/state}/surface11-camera"
[[ -f $libexec/managed-by-surface11-camera && -f $installed && ! -L $installed && -x $libexec/surface-camera-relay ]] || fail 'Managed camera installation is missing.'
[[ ! -L $override ]] || fail "Refusing symlink: $override"
if [[ -f $override ]] && ! grep -q '^# Managed by surface11-camera quality$' "$override"; then
    fail "Refusing unmanaged override: $override"
fi
mkdir -p "$state"
exec 9> "$state/quality.lock"
flock -n 9 || fail 'Another camera quality update is running.'
systemctl --user is-active --quiet surface11-cameras.service || fail 'Camera manager is not running; repair it before tuning.'
for camera in front rear; do
    SURFACE11_CAMERA_QUALITY=$profile bash "$SCRIPT_DIR/surface-camera-relay.sh" "$camera" --validate
done
live_check() {
    # Both sensors together, then reopen: detect broken/frozen public feeds.
    python3 -B - "$SCRIPT_DIR" <<'PY'
import sys
import time
sys.path.insert(0, sys.argv[1])
import importlib
shared = importlib.import_module('check-shared-camera')
routing = importlib.import_module('check-camera-routing')
# systemd's active state precedes publisher registration and session policy.
# Wait for the public routes before opening them; don't restart other services.
for attempt in range(10):
    if not routing.routing_errors(routing.graph_snapshot()):
        break
    time.sleep(1)
else:
    raise RuntimeError('Public camera routes did not become ready')
shared.check_pair()
shared.check_pair()
PY
}
echo 'Checking the existing feeds before making any changes (uncover both lenses).'
live_check || fail 'Baseline capture failed; no installed files were changed.'
mkdir -p "$state/quality-backups"
backup=$(mktemp -d "$state/quality-backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
cp -p "$installed" "$backup/surface-camera-relay.sh"
if [[ -f $override ]]; then
    cp -p "$override" "$backup/quality.conf"
    touch "$backup/had-override"
fi
# A private, versioned wrapper uses the existing installed relay binary. The
# system installation stays untouched; the service override selects this copy.
mkdir "$backup/runtime"
install -m 755 "$SCRIPT_DIR/surface-camera-relay.sh" "$backup/runtime/surface-camera-relay.sh"
ln -s "$libexec/surface-camera-relay" "$backup/runtime/surface-camera-relay"
# Escape systemd specifiers, variable expansion and quoted argument syntax.
exec_path="$backup/runtime/surface-camera-relay.sh"
exec_path=${exec_path//\\/\\\\}
exec_path=${exec_path//\"/\\\"}
exec_path=${exec_path//%/%%}
exec_path=${exec_path//\$/\$\$}
[[ $exec_path != *$'\n'* && $exec_path != *$'\r'* ]] || fail 'Unsupported newline in state directory.'
printf '# Managed by surface11-camera quality\n[Service]\nExecStart=\nExecStart=/usr/bin/bash "%s" run\nEnvironment=SURFACE11_CAMERA_QUALITY=%s\n' "$exec_path" "$profile" > "$backup/new-quality.conf"
echo "Camera backup: $backup"
changed=0
rollback() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e  # Attempt every recovery step even if a preceding restore fails.
    if (( changed )); then
        echo 'Quality update did not pass; restoring the previous camera configuration.' >&2
        if [[ -f $backup/had-override ]]; then
            install -m 644 "$backup/quality.conf" "$override"
        else
            rm -f "$override"
        fi
        systemctl --user daemon-reload
        systemctl --user restart surface11-cameras.service
        live_check || echo "Previous service override restored; camera verification failed. Backup: $backup" >&2
    fi
    exit "$result"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
changed=1
mkdir -p "$(dirname "$override")"
install -m 644 "$backup/new-quality.conf" "$override.quality-new"
mv -f "$override.quality-new" "$override"
systemctl --user daemon-reload
systemctl --user restart surface11-cameras.service
live_check
systemctl --user is-active --quiet surface11-cameras.service surface11-camera-front-publish.service surface11-camera-rear-publish.service
changed=0
echo "PASS: $profile processing; both cameras capture and reopen. Backup retained: $backup"
