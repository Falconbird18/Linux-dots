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
sudo pacman -S --needed iio-sensor-proxy python coreutils
sudo systemctl start iio-sensor-proxy.service
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
marker = '-- SURFACE11_AUTOROTATE_BEGIN'
if marker not in s:
    p.with_name(p.name + '.before-surface11-rotation').write_text(s)
    with p.open('a') as f:
        f.write('''
-- SURFACE11_AUTOROTATE_BEGIN
hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c 'systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY XDG_RUNTIME_DIR && systemctl --user restart surface11-autorotate.service'")
end)
-- SURFACE11_AUTOROTATE_END
''')
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
