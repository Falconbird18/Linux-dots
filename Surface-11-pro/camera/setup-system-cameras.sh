#!/usr/bin/env bash
# Managed by surface11-camera. Run as the logged-in desktop user.
# Creates on-demand standard V4L2 webcams backed by direct libcamera capture.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC=/usr/local/libexec/surface11-camera
CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
UNIT_DIR="$CONF_HOME/systemd/user"
WP_CONF="$CONF_HOME/wireplumber/wireplumber.conf.d/90-surface11-camera.conf"
WP_SCRIPT="$DATA_HOME/wireplumber/scripts/surface11-camera-policy.lua"
WP_PORTAL="$DATA_HOME/wireplumber/scripts/client/find-portal-access.lua"
IPA_DIR="$DATA_HOME/surface11-camera/ipa"
IPA_UNIT="$UNIT_DIR/wireplumber.service.d/90-surface11-camera-ipa.conf"
LEGACY_CPU_UNIT="$UNIT_DIR/wireplumber.service.d/91-surface11-camera-cpu.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/surface11-camera"
[[ $EUID -ne 0 ]] || { echo 'Run as your desktop user; sudo is requested only where needed.' >&2; exit 1; }
fail() { echo "ERROR: $*" >&2; exit 1; }
check_names() {
  [[ $(cat /sys/class/video4linux/video42/name 2>/dev/null) == 'Surface Front Camera' ]] &&
  [[ $(cat /sys/class/video4linux/video43/name 2>/dev/null) == 'Surface Rear Camera' ]]
}
check_routes() {
  # Services and WirePlumber permissions become ready asynchronously at login.
  for attempt in {1..10}; do
    if python3 "$SCRIPT_DIR/check-camera-routing.py"; then return 0; fi
    sleep 1
  done
  echo 'Shared cameras are missing. Relay/publisher startup details:' >&2
  systemctl --user --no-pager --full status \
    surface11-cameras.service \
    surface11-camera-front-publish.service surface11-camera-rear-publish.service || true
  journalctl --user --no-pager --since '-2 minutes' -n 60 \
    -u surface11-cameras \
    -u surface11-camera-front-publish -u surface11-camera-rear-publish || true
  fail 'Camera services did not publish the shared devices; inspect the startup error above.'
}
case "${1:-check}" in
  install)
    [[ $(uname -m) == x86_64 &&
       $(cat /sys/class/dmi/id/sys_vendor) == 'Microsoft Corporation' &&
       $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] ||
      fail 'This camera setup supports only Intel Surface Pro 11 for Business SKU 2103.'
    kernel=$(uname -r)
    [[ -f /usr/lib/modules/$kernel/build/Module.symvers ]] || fail "Matching build tree is missing for $kernel."
    # Keep distro PipeWire libraries matched. Never refresh databases without a full upgrade.
    sudo pacman -S --needed base-devel git python python-gobject dkms v4l2loopback-dkms v4l-utils \
      pipewire wireplumber gst-plugin-libcamera libcamera libcamera-ipa gstreamer gst-plugins-base gst-plugins-good gst-plugin-pipewire \
      meson ninja curl patch python-jinja python-yaml python-ply python-pyparsing libyaml gnutls
    for source in ../tests/check-v4l2-buffers.c ../patches/v4l2loopback-capture-queue.patch check-camera-quality.py loopback-writer.h surface-camera-relay.c check-shared-camera.py surface-camera-publisher.c reprobe-front-sensor.sh surface-camera-ipa-env.sh build-imx681-ipa.sh ../patches/libcamera-imx681-helper.patch ../tests/test-imx681-gain.cpp publish-surface-camera.sh check-camera-routing.py ../wireplumber/90-surface11-camera.conf; do
      [[ -f $SCRIPT_DIR/$source ]] || fail "Missing $source; keep the installer folder together."
    done
    for file in "$WP_CONF"; do
      if [[ -e $file ]] && ! grep -q 'Managed by surface11-camera' "$file"; then fail "Refusing to overwrite $file"; fi
    done
    # Refuse to reuse numbers belonging to unrelated devices.
    for number in 42 43; do
      if [[ -e /sys/class/video4linux/video$number ]]; then
        name=$(cat "/sys/class/video4linux/video$number/name")
        name=${name//\"/}
        [[ $name == 'Surface Front Camera' || $name == 'Surface Rear Camera' ]] || fail "video$number is already used by $name."
      fi
    done
    mkdir -p "$CACHE" "$UNIT_DIR"
    bash "$SCRIPT_DIR/build-imx681-ipa.sh" "$CACHE/imx681-ipa"
    read -r -a relay_flags <<< "$(pkg-config --cflags --libs gstreamer-app-1.0 gstreamer-video-1.0 gio-unix-2.0)"
    cc -O2 -Wall -Wextra "$SCRIPT_DIR/surface-camera-relay.c" -o "$CACHE/surface-camera-relay" "${relay_flags[@]}"
    read -r -a pubflags <<< "$(pkg-config --cflags --libs libpipewire-0.3 gstreamer-app-1.0 gstreamer-video-1.0)"
    cc -O2 -Wall -Wextra "$SCRIPT_DIR/surface-camera-publisher.c" -o "$CACHE/surface-camera-publisher" "${pubflags[@]}"
    bash "$SCRIPT_DIR/surface-camera-relay.sh" front --validate
    bash "$SCRIPT_DIR/surface-camera-relay.sh" rear --validate
    # The custom kernel is installed outside the distro package hooks, so build
    # its loopback module explicitly. This does not change kernel source files.
    bash "$SCRIPT_DIR/../kernel/ensure-camera-module.sh" "$kernel"
    for f in /etc/modprobe.d/surface11-camera.conf /etc/modules-load.d/surface11-camera.conf /etc/udev/rules.d/70-surface11-camera.rules /etc/systemd/system/surface11-camera-sensor.service; do
      if [[ -e $f ]] && ! grep -q 'Managed by surface11-camera' "$f"; then fail "Refusing to overwrite $f"; fi
    done
    if [[ -d $LIBEXEC && ! -f $LIBEXEC/managed-by-surface11-camera ]]; then fail "Unmanaged directory: $LIBEXEC"; fi
    for camera in front rear; do
      for unit in "$UNIT_DIR/surface11-camera-$camera.service" "$UNIT_DIR/surface11-camera-$camera-publish.service"; do
        if [[ -e $unit ]] && ! grep -q 'Managed by surface11-camera' "$unit"; then fail "Refusing to overwrite $unit"; fi
      done
    done
    cat > "$CACHE/modprobe.conf" <<'CONFIG'
# Managed by surface11-camera
options v4l2loopback devices=2 video_nr=42,43 card_label="Surface Front Camera,Surface Rear Camera" exclusive_caps=1,1 max_buffers=16
CONFIG
    printf '# Managed by surface11-camera\nv4l2loopback\n' > "$CACHE/modules.conf"
    cat > "$CACHE/udev.rules" <<'RULES'
# Managed by surface11-camera
SUBSYSTEM=="video4linux", KERNEL=="video42", ATTR{name}=="Surface Front Camera", GROUP="video", MODE="0660", TAG+="uaccess", SYMLINK+="surface-front-camera"
SUBSYSTEM=="video4linux", KERNEL=="video43", ATTR{name}=="Surface Rear Camera", GROUP="video", MODE="0660", TAG+="uaccess", SYMLINK+="surface-rear-camera"
RULES
    mkdir -p "$IPA_DIR"
    if [[ -e $UNIT_DIR/surface11-cameras.service ]] && ! grep -q 'Managed by surface11-camera' "$UNIT_DIR/surface11-cameras.service"; then fail 'Unmanaged shared camera service'; fi
    systemctl --user stop surface11-camera-front-publish.service surface11-camera-rear-publish.service surface11-cameras.service 2>/dev/null || true
    for camera in front rear; do
      old="$UNIT_DIR/surface11-camera-$camera.service"
      if [[ -f $old ]] && grep -q 'Managed by surface11-camera' "$old"; then
        systemctl --user disable --now "surface11-camera-$camera.service"
        rm "$old"
      fi
    done
    sudo install -d "$LIBEXEC"
    sudo touch "$LIBEXEC/managed-by-surface11-camera"
    sudo install -m 755 "$CACHE/surface-camera-relay" "$LIBEXEC/surface-camera-relay"
    sudo rm -f "$LIBEXEC/v4l2-relayd"
    sudo install -m 755 "$CACHE/surface-camera-publisher" "$LIBEXEC/surface-camera-publisher"
    sudo install -m 755 "$SCRIPT_DIR/reprobe-front-sensor.sh" "$LIBEXEC/reprobe-front-sensor.sh"
    sudo install -m 755 "$SCRIPT_DIR/surface-camera-relay.sh" "$LIBEXEC/surface-camera-relay.sh"
    sudo install -m 755 "$SCRIPT_DIR/publish-surface-camera.sh" "$LIBEXEC/publish-surface-camera.sh"
    sudo install -m 755 "$SCRIPT_DIR/surface-camera-ipa-env.sh" "$LIBEXEC/surface-camera-ipa-env.sh"
    mkdir -p "$(dirname "$WP_CONF")"
    cat > "$CACHE/sensor.service" <<UNIT
# Managed by surface11-camera
[Unit]
Description=Retry an unbound Intel Surface front camera after initial module probing
After=systemd-modules-load.service
Before=systemd-user-sessions.service
[Service]
Type=oneshot
ExecStart=$LIBEXEC/reprobe-front-sensor.sh
[Install]
WantedBy=multi-user.target
UNIT
    sudo install -m 644 "$CACHE/sensor.service" /etc/systemd/system/surface11-camera-sensor.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now surface11-camera-sensor.service
    wp_changed=0
    cmp -s "$SCRIPT_DIR/../wireplumber/90-surface11-camera.conf" "$WP_CONF" || wp_changed=1
    install -m 644 "$SCRIPT_DIR/../wireplumber/90-surface11-camera.conf" "$WP_CONF"
    install -m 755 "$CACHE/imx681-ipa/ipa/ipa_soft_simple.so" "$IPA_DIR/ipa_soft_simple.so"
    install -m 644 "$CACHE/imx681-ipa/packages.txt" "$IPA_DIR/packages.txt"
    # Retire the managed native-backend permission and audio-process IPA experiments.
    for file in "$WP_SCRIPT" "$WP_PORTAL" "$IPA_UNIT" "$LEGACY_CPU_UNIT"; do
      if [[ -f $file ]] && grep -q 'Managed by surface11-camera' "$file"; then
        rm "$file"
        wp_changed=1
      fi
    done
    sudo rm -f "$LIBEXEC/prepare-camera-portal.py"
    bash "$SCRIPT_DIR/surface-camera-ipa-env.sh" "$IPA_DIR" "$CACHE/ipa-env"
    sudo install -m 644 "$CACHE/modprobe.conf" /etc/modprobe.d/surface11-camera.conf
    sudo install -m 644 "$CACHE/modules.conf" /etc/modules-load.d/surface11-camera.conf
    sudo install -m 644 "$CACHE/udev.rules" /etc/udev/rules.d/70-surface11-camera.rules
    sudo udevadm control --reload-rules
    module_changed=0
    if [[ -f /sys/module/v4l2loopback/srcversion ]] &&
       [[ $(cat /sys/module/v4l2loopback/srcversion) != "$(modinfo -F srcversion v4l2loopback)" ]]; then
      module_changed=1
    fi
    if [[ -f /sys/module/v4l2loopback/parameters/max_buffers ]] &&
       [[ $(cat /sys/module/v4l2loopback/parameters/max_buffers) != 16 ]]; then module_changed=1; fi
    if [[ -d /sys/module/v4l2loopback ]] && { ! check_names || (( module_changed )); }; then
      # Recover only our known malformed labels, never unrelated webcams.
      for number in 42 43; do
        name=$(cat "/sys/devices/virtual/video4linux/video$number/name" 2>/dev/null) || fail 'Existing loopback devices are unrelated; close their users and unload v4l2loopback before retrying.'
        name=${name//\"/}
        case "$number:$name" in
          '42:Surface Front Camera'|'43:Surface Rear Camera') ;;
          *) fail 'Existing loopback devices are unrelated; refusing to unload them.' ;;
        esac
      done
      for path in /sys/devices/virtual/video4linux/video*; do
        [[ -e $path ]] || continue
        [[ ${path##*/} == video42 || ${path##*/} == video43 ]] || fail 'Other virtual cameras exist; refusing automatic module reload.'
      done
      systemctl --user stop surface11-camera-front-publish.service surface11-camera-rear-publish.service \
        surface11-cameras.service 2>/dev/null || true
      sudo modprobe -r v4l2loopback || fail 'Camera devices are busy. Fully quit camera apps, then rerun install.'
    fi
    sudo modprobe v4l2loopback
    sudo udevadm trigger --subsystem-match=video4linux --sysname-match=video42 --action=change
    sudo udevadm trigger --subsystem-match=video4linux --sysname-match=video43 --action=change
    sudo udevadm settle
    check_names || fail 'Expected video42/video43 names were not created. Check other v4l2loopback module options.'
    cat > "$UNIT_DIR/surface11-cameras.service" <<UNIT
# Managed by surface11-camera
[Unit]
Description=Surface cameras with a shared libcamera manager
After=pipewire.service wireplumber.service
PartOf=wireplumber.service
Wants=pipewire.service wireplumber.service surface11-camera-front-publish.service surface11-camera-rear-publish.service
StartLimitIntervalSec=120
StartLimitBurst=5
[Service]
ExecStart=$LIBEXEC/surface-camera-relay.sh run
ExecStartPre=$LIBEXEC/surface-camera-ipa-env.sh "$IPA_DIR" "$CACHE/ipa-env"
EnvironmentFile=-$CACHE/ipa-env
Environment=LIBCAMERA_SOFTISP_MODE=cpu
Environment=GST_DEBUG=2
Restart=always
RestartSec=5
TimeoutStopSec=10
[Install]
WantedBy=default.target
UNIT
    for camera in front rear; do
      cat > "$UNIT_DIR/surface11-camera-$camera-publish.service" <<UNIT
# Managed by surface11-camera
[Unit]
Description=Publish Surface $camera webcam to PipeWire apps
After=surface11-cameras.service wireplumber.service
BindsTo=surface11-cameras.service
PartOf=surface11-cameras.service
[Service]
ExecStart=$LIBEXEC/publish-surface-camera.sh $camera
Restart=always
RestartSec=3
TimeoutStopSec=5
[Install]
WantedBy=default.target
UNIT
    done
    # Retire only the previous app-specific experiment, not the normal launcher.
    for legacy in "$DATA_HOME/applications/surface11-discord-camera.desktop" "$DATA_HOME/surface11-camera/discord-camera"; do
      if [[ -f $legacy ]] && grep -q 'surface11-camera' "$legacy"; then rm "$legacy"; fi
    done
    systemctl --user daemon-reload
    systemctl --user enable surface11-cameras.service
    systemctl --user reset-failed surface11-cameras.service surface11-camera-front-publish.service surface11-camera-rear-publish.service
    if (( wp_changed )); then
      # Load the visibility policy; restarting only WirePlumber briefly refreshes
      # device routing. Keep PipeWire itself and its audio streams running.
      systemctl --user stop surface11-camera-front-publish.service surface11-camera-rear-publish.service \
        surface11-cameras.service
      systemctl --user restart wireplumber.service
    fi
    systemctl --user restart surface11-cameras.service
    systemctl --user enable --now surface11-camera-front-publish.service surface11-camera-rear-publish.service
    check_routes
    echo 'Installed. Two named webcams start at login; direct libcamera capture starts on client demand.'
    echo 'Use Surface Front Camera or Surface Rear Camera from normal application launchers.'
    ;;
  quality)
    check_names || fail 'Standard Surface webcams are not installed. Run install first.'
    check_routes
    for number in 42 43; do
      v4l2-ctl -d "/dev/video$number" --get-fmt-video --get-parm
    done
    python3 "$SCRIPT_DIR/check-camera-quality.py"
    ;;
  check)
    check_started=$(date --iso-8601=seconds)
    check_names || fail 'Standard Surface webcam devices are not installed. Run install first.'
    check_routes
    systemctl --user --no-pager status surface11-cameras.service
    failed=0
    capture_dir=$(mktemp -d)
    trap 'rm -rf "$capture_dir"' EXIT
    # Actual images must change after warmup, twice per camera across reopen.
    # A fakesink consuming 30 placeholders was not sufficient evidence.
    if ! python3 -u "$SCRIPT_DIR/check-shared-camera.py"; then failed=1; fi
    # Retain mmap frames while the producer runs: catches unqueued dequeues and
    # writes into application-owned buffers that a fakesink cannot reveal.
    cc -O2 -Wall -Wextra "$SCRIPT_DIR/../tests/check-v4l2-buffers.c" -o "$capture_dir/check-buffers"
    for number in 42 43; do
      if ! timeout --kill-after=2s 45s "$capture_dir/check-buffers" "/dev/video$number"; then failed=1; fi
    done
    echo 'Recent relay/publisher logs (no images are saved):'
    journalctl --user -u surface11-cameras \
      -u surface11-camera-front-publish -u surface11-camera-rear-publish \
      --since "$check_started" -n 60 --no-pager
    exit "$failed"
    ;;
  undo)
    if grep -q 'Managed by surface11-camera' /etc/systemd/system/surface11-camera-sensor.service 2>/dev/null; then
      sudo systemctl disable --now surface11-camera-sensor.service || true
    fi
    systemctl --user disable --now surface11-camera-front-publish.service surface11-camera-rear-publish.service || true
    systemctl --user disable --now surface11-cameras.service || true
    rm -f "$UNIT_DIR/surface11-cameras.service" "$UNIT_DIR/surface11-camera-front.service" "$UNIT_DIR/surface11-camera-rear.service"
    rm -f "$UNIT_DIR/surface11-camera-front-publish.service" "$UNIT_DIR/surface11-camera-rear-publish.service"
    wp_removed=0
    for file in "$WP_CONF" "$WP_SCRIPT" "$WP_PORTAL" "$IPA_UNIT" "$LEGACY_CPU_UNIT"; do
      if [[ -f $file ]] && grep -q 'Managed by surface11-camera' "$file"; then rm "$file"; wp_removed=1; fi
    done
    rm -f "$IPA_DIR/ipa_soft_simple.so" "$IPA_DIR/packages.txt" "$CACHE/ipa-env"
    systemctl --user daemon-reload
    if (( wp_removed )); then systemctl --user restart wireplumber.service; fi
    systemctl --user daemon-reload
    for f in /etc/modprobe.d/surface11-camera.conf /etc/modules-load.d/surface11-camera.conf /etc/udev/rules.d/70-surface11-camera.rules /etc/systemd/system/surface11-camera-sensor.service; do
      if [[ -f $f ]] && grep -q 'Managed by surface11-camera' "$f"; then sudo rm "$f"; fi
    done
    if [[ -f $LIBEXEC/managed-by-surface11-camera ]]; then
      sudo rm -f "$LIBEXEC/v4l2-relayd" "$LIBEXEC/surface-camera-relay" "$LIBEXEC/surface-camera-relay.sh" "$LIBEXEC/publish-surface-camera.sh" "$LIBEXEC/surface-camera-ipa-env.sh" "$LIBEXEC/prepare-camera-portal.py" "$LIBEXEC/surface-camera-publisher" "$LIBEXEC/reprobe-front-sensor.sh" "$LIBEXEC/managed-by-surface11-camera"
      sudo rmdir "$LIBEXEC"
    fi
    sudo systemctl daemon-reload
    sudo udevadm control --reload-rules
    echo 'Removed services and boot configuration. Reboot to remove the idle webcam devices. Packages are retained.'
    ;;
  *) fail 'Usage: bash setup-system-cameras.sh {install|check|quality|undo}' ;;
esac
