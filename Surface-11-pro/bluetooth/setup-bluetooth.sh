#!/usr/bin/env bash
# Reproducible BlueZ setup for the Intel Surface Pro 11 PCIe controller.
set -euo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user.'
[[ $(uname -m) == x86_64 && $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] || fail 'Unsupported Surface model.'
mode=${1:-check}
[[ $mode == install || $mode == check ]] || fail 'Usage: setup-bluetooth.sh {install|check}'
if [[ $mode == install ]]; then
  sudo pacman -S --needed bluez bluez-utils linux-firmware-intel
  modinfo btintel_pcie >/dev/null || fail 'Running kernel lacks btintel_pcie; boot the supplied kernel.'
  sudo modprobe btintel_pcie
  sudo rfkill unblock bluetooth
  sudo systemctl enable --now bluetooth.service
fi
systemctl is-active --quiet bluetooth.service || fail 'bluetooth.service is stopped; run install-surface11.sh bluetooth.'
# --timeout is a scan timeout in bluetoothctl, so also bound the whole process.
controllers=
for attempt in {1..15}; do
  controllers=$(timeout --kill-after=2s 5s bluetoothctl list) || true
  [[ $controllers == *'Controller '* ]] && break
  sleep 1
done
if [[ $controllers != *'Controller '* ]]; then
  rfkill list bluetooth || true
  journalctl -b -k --no-pager -n 200 | rg -i 'bluetooth|btintel|hci' || true
  fail 'BlueZ has no controller; firmware/driver initialization needs investigation.'
fi
printf '%s\n' "$controllers"
if [[ $mode == install ]]; then
  timeout --kill-after=2s 10s bluetoothctl power on || fail 'Could not power Bluetooth on; check rfkill/firmware logs.'
fi
timeout --kill-after=2s 5s bluetoothctl show
systemctl is-enabled --quiet bluetooth.service || fail 'Bluetooth is not enabled at boot.'
echo 'PASS: BlueZ is enabled and exposes a Bluetooth controller.'
