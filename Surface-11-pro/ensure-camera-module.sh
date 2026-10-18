#!/usr/bin/env bash
# Recover missing custom-kernel modules even when DKMS still says "installed".
set -euo pipefail
kernel="${1:-$(uname -r)}"
mode="${2:-check}"
[[ $mode == check || $mode == rebuild ]] || { echo 'Expected check or rebuild mode' >&2; exit 2; }
[[ -f /usr/lib/modules/$kernel/build/Module.symvers ]] || {
  echo "Missing configured build tree for $kernel" >&2; exit 1;
}
package=$(pacman -Q v4l2loopback-dkms)
version=${package##* }
version=${version#*:}
version=${version%-*}
[[ -f /usr/src/v4l2loopback-$version/dkms.conf ]] || {
  echo "Missing v4l2loopback $version DKMS source" >&2; exit 1;
}
# Repair a missing/outdated module index before deciding to reinstall.
sudo depmod -a "$kernel"
if [[ $mode == rebuild ]]; then
  # Kernel rebuilds can reuse the release string while changing module ABI.
  sudo dkms build --force -m v4l2loopback -v "$version" -k "$kernel"
fi
if [[ $mode == rebuild ]] || ! modinfo -k "$kernel" v4l2loopback >/dev/null 2>&1; then
  echo "Installing v4l2loopback $version for $kernel (repairing any stale DKMS record)..."
  sudo dkms install --force -m v4l2loopback -v "$version" -k "$kernel"
  sudo depmod -a "$kernel"
fi
modinfo -k "$kernel" v4l2loopback >/dev/null || {
  echo "v4l2loopback remains unavailable for $kernel after reinstall." >&2; exit 1;
}
echo "Verified v4l2loopback for $kernel."
