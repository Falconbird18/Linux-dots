#!/usr/bin/env bash
# Run as the desktop user, with sudo only for package installation.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] || { echo 'Run as the desktop user.' >&2; exit 1; }
case ${1:-install} in
  install) sudo pacman -S --needed squeekboard python ;;
  --configure-only) ;; # Prepare configuration when package installation is unavailable.
  status) systemctl --user --no-pager status surface11-touch.service; exit ;;
  *) echo 'Usage: setup-touch.sh [install|status|--configure-only]' >&2; exit 2 ;;
esac
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
config="$config_home/hypr/hyprland.lua"
[[ -f $config ]] || { echo "Missing $config" >&2; exit 1; }
install -Dm644 "$SCRIPT_DIR/surface11-touch.py" "$HOME/.local/lib/surface11/touch.py"
install -Dm644 "$SCRIPT_DIR/touch.lua" "$config_home/hypr/surface11-touch.lua"
python3 - "$config" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
line = 'require("surface11-touch")'
if line not in s:
    p.with_name(p.name + '.before-surface11-touch').write_text(s)
    p.write_text(s + '\n-- Surface touchscreen and desktop input method\n' + line + '\n')
PY
mkdir -p "$config_home/systemd/user"
cat > "$config_home/systemd/user/surface11-touch.service" <<'UNIT'
[Unit]
Description=Surface tablet desktop keyboard
PartOf=hyprland-session.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/python3 "%h/.local/lib/surface11/touch.py"
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
Environment=GTK_THEME=Adwaita:dark

[Install]
WantedBy=hyprland-session.target
UNIT
# Make the keyboard available through Dux's launcher and dock as well as text focus.
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
cat > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/surface11-keyboard.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Show Touch Keyboard
Comment=Show the tablet keyboard for apps without automatic text input
Exec=busctl --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b true
Icon=input-keyboard
Categories=Utility;Accessibility;
Terminal=false
DESKTOP
# The service follows keyboard/tablet state and controls Dux dock auto-hide.
systemctl --user daemon-reload
systemctl --user enable surface11-touch.service
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY XDG_RUNTIME_DIR
    hyprctl reload
    systemctl --user restart surface11-touch.service
fi
if ! command -v squeekboard >/dev/null; then
    echo 'Configuration prepared; install squeekboard, then rerun this script without --configure-only.' >&2
    exit 1
fi
echo 'Touch setup installed. Detach the keyboard and tap a Wayland text field.'
echo 'Dux lock screen: tap the keyboard button beside the password field.'
