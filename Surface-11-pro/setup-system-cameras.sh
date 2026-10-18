#!/usr/bin/env bash
# Managed by surface11-camera. Run as the logged-in desktop user.
# Creates on-demand standard V4L2 webcams backed by native PipeWire cameras.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RELAY_REF=7ecae8774f3f6c9f8eb0c8d15e9ee03cdff62a96
RELAY_URL=https://gitlab.com/canonical-mainstream/v4l2-relayd.git
LIBEXEC=/usr/local/libexec/surface11-camera
CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
UNIT_DIR="$CONF_HOME/systemd/user"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/surface11-camera"
[[ $EUID -ne 0 ]] || { echo 'Run as your desktop user; sudo is requested only where needed.' >&2; exit 1; }
fail() { echo "ERROR: $*" >&2; exit 1; }
check_names() {
  [[ $(cat /sys/class/video4linux/video42/name 2>/dev/null) == 'Surface Front Camera' ]] &&
  [[ $(cat /sys/class/video4linux/video43/name 2>/dev/null) == 'Surface Rear Camera' ]]
}
case "${1:-check}" in
  install)
    kernel=$(uname -r)
    [[ -f /usr/lib/modules/$kernel/build/Module.symvers ]] || fail "Matching build tree is missing for $kernel."
    # Keep distro PipeWire libraries matched. Never refresh databases without a full upgrade.
    sudo pacman -S --needed base-devel git python dkms v4l2loopback-dkms v4l-utils \
      pipewire-libcamera libcamera libcamera-ipa gstreamer gst-plugins-base gst-plugins-good gst-plugin-pipewire
    # Refuse to reuse numbers belonging to unrelated devices.
    for number in 42 43; do
      if [[ -e /sys/class/video4linux/video$number ]]; then
        name=$(cat "/sys/class/video4linux/video$number/name")
        [[ $name == 'Surface Front Camera' || $name == 'Surface Rear Camera' ]] || fail "video$number is already used by $name."
      fi
    done
    mkdir -p "$CACHE" "$UNIT_DIR"
    if [[ ! -d $CACHE/relay-source/.git ]]; then
      git clone --no-checkout "$RELAY_URL" "$CACHE/relay-source"
    fi
    git -C "$CACHE/relay-source" cat-file -e "$RELAY_REF^{commit}" 2>/dev/null ||
      git -C "$CACHE/relay-source" fetch origin "$RELAY_REF"
    # Extract the pinned file, without modifying the checkout or kernel sources.
    git -C "$CACHE/relay-source" show "$RELAY_REF:src/v4l2-relayd.c" > "$CACHE/relay.c"
    python3 - "$CACHE/relay.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
old = '#define V4L2_EVENT_PRI_CLIENT_USAGE  V4L2_EVENT_PRIVATE_START'
new = '#define V4L2_EVENT_PRI_CLIENT_USAGE (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)'
if s.count(old) != 1:
    raise SystemExit('Unexpected relay source; refusing an unverified event API change.')
s = s.replace(old, new)
# The upstream idle transition checks input_pipeline twice; check the splash
# object before changing its state instead.
s = s.replace('if (input_pipeline != NULL)\n    gst_element_set_state (splash_pipeline,',
              'if (splash_pipeline != NULL)\n    gst_element_set_state (splash_pipeline,')
p.write_text(s)
PY
    read -r -a ccflags <<< "$(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gio-unix-2.0)"
    read -r -a ldflags <<< "$(pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gio-unix-2.0)"
    cc -O2 -Wall "-DV4L2_RELAYD_VERSION=\"surface11-$RELAY_REF\"" "${ccflags[@]}" \
      "$CACHE/relay.c" -o "$CACHE/v4l2-relayd" "${ldflags[@]}"
    "$CACHE/v4l2-relayd" --version
    # The custom kernel is installed outside the distro package hooks, so build
    # its loopback module explicitly. This does not change kernel source files.
    bash "$SCRIPT_DIR/ensure-camera-module.sh" "$kernel"
    for f in /etc/modprobe.d/surface11-camera.conf /etc/modules-load.d/surface11-camera.conf /etc/udev/rules.d/70-surface11-camera.rules; do
      if [[ -e $f ]] && ! grep -q 'Managed by surface11-camera' "$f"; then fail "Refusing to overwrite $f"; fi
    done
    if [[ -d $LIBEXEC && ! -f $LIBEXEC/managed-by-surface11-camera ]]; then fail "Unmanaged directory: $LIBEXEC"; fi
    for camera in front rear; do
      unit="$UNIT_DIR/surface11-camera-$camera.service"
      if [[ -e $unit ]] && ! grep -q 'Managed by surface11-camera' "$unit"; then fail "Refusing to overwrite $unit"; fi
    done
    cat > "$CACHE/modprobe.conf" <<'CONFIG'
# Managed by surface11-camera
options v4l2loopback devices=2 video_nr=42,43 card_label="Surface Front Camera","Surface Rear Camera" exclusive_caps=1,1 max_buffers=4
CONFIG
    printf '# Managed by surface11-camera\nv4l2loopback\n' > "$CACHE/modules.conf"
    cat > "$CACHE/udev.rules" <<'RULES'
# Managed by surface11-camera
SUBSYSTEM=="video4linux", KERNEL=="video42", ATTR{name}=="Surface Front Camera", GROUP="video", MODE="0660", TAG+="uaccess", SYMLINK+="surface-front-camera"
SUBSYSTEM=="video4linux", KERNEL=="video43", ATTR{name}=="Surface Rear Camera", GROUP="video", MODE="0660", TAG+="uaccess", SYMLINK+="surface-rear-camera"
RULES
    # Do not unload an existing loopback module that OBS or another app may use.
    if [[ -d /sys/module/v4l2loopback ]] && ! check_names; then
      fail 'v4l2loopback is already loaded without our cameras. Close apps and unload it, or reboot after configuring it; no active module was unloaded.'
    fi
    sudo install -d "$LIBEXEC"
    sudo touch "$LIBEXEC/managed-by-surface11-camera"
    sudo install -m 755 "$CACHE/v4l2-relayd" "$LIBEXEC/v4l2-relayd"
    sudo install -m 755 "$SCRIPT_DIR/surface-camera-relay.sh" "$LIBEXEC/surface-camera-relay.sh"
    sudo install -m 644 "$CACHE/modprobe.conf" /etc/modprobe.d/surface11-camera.conf
    sudo install -m 644 "$CACHE/modules.conf" /etc/modules-load.d/surface11-camera.conf
    sudo install -m 644 "$CACHE/udev.rules" /etc/udev/rules.d/70-surface11-camera.rules
    sudo udevadm control --reload-rules
    sudo modprobe v4l2loopback
    sudo udevadm trigger --subsystem-match=video4linux --sysname-match=video42 --action=change
    sudo udevadm trigger --subsystem-match=video4linux --sysname-match=video43 --action=change
    sudo udevadm settle
    check_names || fail 'Expected video42/video43 names were not created. Check other v4l2loopback module options.'
    for camera in front rear; do
      cat > "$UNIT_DIR/surface11-camera-$camera.service" <<UNIT
# Managed by surface11-camera
[Unit]
Description=Surface $camera camera as a standard V4L2 webcam
After=pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service
StartLimitIntervalSec=120
StartLimitBurst=5
[Service]
ExecStart=$LIBEXEC/surface-camera-relay.sh $camera
Restart=always
RestartSec=5
TimeoutStopSec=10
Environment=GST_DEBUG=2
[Install]
WantedBy=default.target
UNIT
    done
    # Retire only the previous app-specific experiment, not the normal launcher.
    rm -f "$DATA_HOME/applications/surface11-discord-camera.desktop" "$DATA_HOME/surface11-camera/discord-camera"
    if command -v update-desktop-database >/dev/null; then update-desktop-database "$DATA_HOME/applications"; fi
    systemctl --user daemon-reload
    systemctl --user enable surface11-camera-front.service surface11-camera-rear.service
    systemctl --user restart surface11-camera-front.service surface11-camera-rear.service
    echo 'Installed. Two named V4L2 cameras start at login; physical capture starts on client demand.'
    echo 'Quit Discord fully, then use its NORMAL launcher. Run this script with check before opening it.'
    ;;
  check)
    check_names || fail 'Standard Surface webcam devices are not installed. Run install first.'
    systemctl --user --no-pager status surface11-camera-front.service surface11-camera-rear.service
    failed=0
    capture_dir=$(mktemp -d)
    trap 'rm -rf "$capture_dir"' EXIT
    for number in 42 43; do
      echo "Testing $(cat "/sys/class/video4linux/video$number/name")..."
      if timeout --kill-after=2s 15s v4l2-ctl -d "/dev/video$number" \
          --stream-mmap=3 --stream-count=60 --stream-to="$capture_dir/frames.raw"; then
        # A working loopback alone can emit its idle black placeholder. Reject
        # uniform output rather than claiming the physical sensor is working.
        if python3 - "$capture_dir/frames.raw" <<'PYIMAGE'
from pathlib import Path
import sys
raw = Path(sys.argv[1]).read_bytes()
frame_size = 640 * 480 * 2
if len(raw) < frame_size:
    raise SystemExit('FAIL: No complete YUYV frame.')
y = raw[-frame_size::2]
if max(y) - min(y) <= 2:
    raise SystemExit('INCONCLUSIVE: uniform/black output. Aim at a lit scene and retry; the sensor may not be streaming.')
print('PASS: complete frames with nonuniform image data; check the preview for the correct camera.')
PYIMAGE
        then :; else failed=1; fi
      else
        echo "FAIL: video$number" >&2; failed=1
      fi
    done
    echo 'Recent relay logs (no images are saved):'
    journalctl --user -u surface11-camera-front -u surface11-camera-rear -n 25 --no-pager
    exit "$failed"
    ;;
  undo)
    systemctl --user disable --now surface11-camera-front.service surface11-camera-rear.service || true
    rm -f "$UNIT_DIR/surface11-camera-front.service" "$UNIT_DIR/surface11-camera-rear.service"
    systemctl --user daemon-reload
    for f in /etc/modprobe.d/surface11-camera.conf /etc/modules-load.d/surface11-camera.conf /etc/udev/rules.d/70-surface11-camera.rules; do
      if [[ -f $f ]] && grep -q 'Managed by surface11-camera' "$f"; then sudo rm "$f"; fi
    done
    if [[ -f $LIBEXEC/managed-by-surface11-camera ]]; then
      sudo rm -f "$LIBEXEC/v4l2-relayd" "$LIBEXEC/surface-camera-relay.sh" "$LIBEXEC/managed-by-surface11-camera"
      sudo rmdir "$LIBEXEC"
    fi
    sudo udevadm control --reload-rules
    echo 'Removed services and boot configuration. Reboot to remove the idle webcam devices. Packages are retained.'
    ;;
  *) fail 'Usage: bash setup-system-cameras.sh {install|check|undo}' ;;
esac
