#!/usr/bin/env bash
# Managed by surface11-camera. Retry only an unbound Surface front sensor.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Front sensor retry requires root.' >&2; exit 1; }
[[ $(cat /sys/class/dmi/id/sys_vendor) == 'Microsoft Corporation' &&
   $(cat /sys/class/dmi/id/product_sku) == Surface_Pro_11th_Edition_With_Intel_For_Business_2103 ]] || exit 1
sensor=/sys/bus/i2c/devices/i2c-SONY0681:00
[[ -d $sensor ]] || { echo 'Surface front sensor ACPI device is absent.' >&2; exit 1; }
# Never unbind or reload an active sensor, IPU controller, or unrelated driver.
[[ ! -L $sensor/driver ]] || exit 0
modprobe imx681
for attempt in 1 2 3; do
  [[ ! -L $sensor/driver ]] || exit 0
  sleep 1
  printf '%s\n' i2c-SONY0681:00 > /sys/bus/i2c/drivers_probe || true
  if [[ -L $sensor/driver ]]; then
    echo 'Surface front sensor bound successfully after startup retry.'
    exit 0
  fi
done
echo 'Front IMX681 still fails to bind. Inspect journalctl -k -b; no driver was unloaded.' >&2
exit 1
