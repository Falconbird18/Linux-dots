#!/usr/bin/env bash
# Install into the user's session; never run the entire script as root.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] || { echo 'Run as the desktop user.' >&2; exit 1; }
mode=${1:-install}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
unit_dir="$config_home/systemd/user"
case "$mode" in
  status)
    systemctl --user --no-pager status surface11-autorotate.service
    exit ;;
  install) ;;
  *) echo 'Usage: setup-autorotation.sh [install|status]' >&2; exit 2 ;;
esac
command -v hyprctl >/dev/null || { echo 'Install Hyprland first.' >&2; exit 1; }
config="$config_home/hypr/hyprland.lua"
[[ -f $config ]] || { echo "Expected Lua Hyprland configuration: $config" >&2; exit 1; }
if ! pacman -Q iio-sensor-proxy python coreutils >/dev/null 2>&1; then
  sudo pacman -S --needed iio-sensor-proxy python coreutils
fi
# The Surface SAM HID transport cannot fetch input reports on demand. With the
# firmware's on-change threshold, stationary sensors time out and supply bogus
# zeroes to SensorProxy's polling fallback. Install this before starting/reprobing
# SensorProxy so it discovers a continuously reporting, buffered accelerometer.
sudo install -Dm644 "$SCRIPT_DIR/81-surface11-accelerometer.rules" /etc/udev/rules.d/81-surface11-accelerometer.rules
sudo udevadm control --reload-rules
if [[ $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) == 'Microsoft Corporation' &&
      $(cat /sys/class/dmi/id/product_name 2>/dev/null) == 'Surface Pro for Business 11th Edition with Intel' ]]; then
  sudo udevadm trigger --settle --action=change --subsystem-match=iio --attr-match=name=accel_3d
  sudo systemctl restart iio-sensor-proxy.service
  echo 'Applied Surface Pro 11 Intel continuous accelerometer reporting fix.'
elif ! systemctl is-active --quiet iio-sensor-proxy.service; then
  sudo systemctl start iio-sensor-proxy.service
fi
install -Dm644 "$SCRIPT_DIR/surface11-autorotate.py" "$HOME/.local/lib/surface11/autorotate.py"
mkdir -p "$unit_dir"
cat > "$unit_dir/surface11-autorotate.service" <<'UNIT'
[Unit]
Description=Surface Pro 11 Hyprland auto-rotation
PartOf=hyprland-session.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 "%h/.local/lib/surface11/autorotate.py"
Restart=on-failure
RestartSec=5
TimeoutStopSec=8

[Install]
WantedBy=hyprland-session.target
UNIT
# The startup hook also supports sessions that do not start hyprland-session.target.
# Import only the environment required to reach this compositor instance.
python3 - "$config" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
begin = '-- SURFACE11_AUTOROTATE_BEGIN'
end = '-- SURFACE11_AUTOROTATE_END'
hook = begin + '''
hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c 'systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR && systemctl --user restart surface11-autorotate.service'")
end)

hl.on("config.reloaded", function()
    hl.exec_cmd("systemctl --user try-restart surface11-autorotate.service")
end)
''' + end
if begin in s:
    first = s.index(begin)
    last = s.index(end, first) + len(end)
    updated = s[:first] + hook + s[last:]
else:
    p.with_name(p.name + '.before-surface11-rotation').write_text(s)
    updated = s + '\n' + hook + '\n'
if updated != s:
    p.write_text(updated)
PY
systemctl --user daemon-reload
systemctl --user enable surface11-autorotate.service
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR
  if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    systemctl --user import-environment WAYLAND_DISPLAY
  fi
  systemctl --user restart surface11-autorotate.service
fi
echo 'Auto-rotation installed. Starts now in Hyprland, or at the next Hyprland login.'
echo 'Logs: journalctl --user -u surface11-autorotate.service -f'
