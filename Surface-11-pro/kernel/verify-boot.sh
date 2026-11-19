#!/usr/bin/env bash
# Read-only verification of this installer's systemd-boot assets.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/version.env"
release="$KERNEL_VERSION$CUSTOM_SUFFIX"
stem="linux-$release"
esp=/efi
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Use install-surface11.sh verify-boot to authenticate with sudo.'
mountpoint -q "$esp" || fail 'The EFI partition is not mounted at /efi.'
build=$(readlink -f "/usr/lib/modules/$release/build")
[[ -s $build/arch/x86/boot/bzImage && -s $build/Module.symvers ]] || fail 'Matching completed build tree is missing.'
cmp -s "$build/arch/x86/boot/bzImage" "$esp/vmlinuz-$stem" || fail 'EFI kernel image differs from the completed build.'
cmp -s "$build/.config" "$esp/config-$stem" || fail 'Installed kernel config differs from the build.'
echo "PASS: installed kernel image and config match the completed $release build"
sha256sum "$esp/vmlinuz-$stem"

python3 - "$esp" "$release" <<'PY'
from pathlib import Path
import shlex
import sys

esp = Path(sys.argv[1])
release = sys.argv[2]

def entry(path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        # Accept tabs as well as spaces in loader entries.
        key, *rest = line.split(None, 1)
        result.setdefault(key, []).append(rest[0] if rest else '')
    for key in ('linux', 'initrd'):
        for value in result.get(key, []):
            if not value.startswith('/') or '..' in Path(value).parts:
                raise SystemExit(f'ERROR: unexpected {key} path: {value}')
            asset = esp / value.lstrip('/')
            if not asset.is_file() or asset.stat().st_size == 0:
                raise SystemExit(f'ERROR: missing or empty boot asset: {asset}')
    if len(result.get('linux', [])) != 1 or not result.get('initrd'):
        raise SystemExit(f'ERROR: incomplete boot entry: {path}')
    return result

path = esp / 'loader/entries' / f'{release}.conf'
new = entry(path)
if new['linux'] != [f'/vmlinuz-linux-{release}'] or new['initrd'] != [f'/initramfs-linux-{release}.img']:
    raise SystemExit('ERROR: new entry references unexpected kernel/initramfs files')
current = [a for a in shlex.split(Path('/proc/cmdline').read_text())
           if not a.startswith(('initrd=', 'BOOT_IMAGE='))]
installed = shlex.split(' '.join(new.get('options', [])))
if installed != current or not any(a.startswith('root=') for a in installed):
    raise SystemExit('ERROR: boot options do not preserve the running system root/options')
print('PASS: new boot entry references the correct files and preserves root/options')
print(path.read_text().rstrip())

running = Path('/proc/sys/kernel/osrelease').read_text().strip()
if running != release:
    # The older installer used this fixed entry name; versioned installs use
    # the release itself. Check whichever describes the current working kernel.
    candidates = [esp / 'loader/entries' / f'{running}.conf',
                  esp / 'loader/entries/surface11-camera1.conf']
    for candidate in candidates:
        if candidate.is_file() and running in candidate.read_text():
            entry(candidate)
            print(f'PASS: working {running} fallback entry and its boot files remain')
            break
    else:
        raise SystemExit(f'ERROR: cannot verify a fallback entry for {running}')

secure_boot = list(Path('/sys/firmware/efi/efivars').glob('SecureBoot-*'))
if len(secure_boot) != 1:
    raise SystemExit('ERROR: cannot determine UEFI Secure Boot state')
state = secure_boot[0].read_bytes()[4:5]
if state != b'\0':
    raise SystemExit('ERROR: Secure Boot is enabled; this verifier cannot certify image signing/enrollment')
print('PASS: UEFI Secure Boot is disabled')
PY

initrd="$esp/initramfs-$stem.img"
listing=$(lsinitrd "$initrd") || fail 'Cannot parse the installed initramfs.'
[[ $listing == *"lib/modules/$release/"* ]] || fail 'Initramfs does not contain modules for the target release.'
for module in nvme nvme-core; do
  [[ $listing == *"lib/modules/$release/kernel/drivers/nvme/host/$module.ko"* ]] || fail "Initramfs is missing $module, required for this Surface's NVMe root disk."
done
echo "PASS: initramfs parses and includes $release NVMe boot modules"
for module in imx681 ov13858 intel_ipu7 btintel_pcie v4l2loopback; do
  magic=$(modinfo -k "$release" -F vermagic "$module")
  [[ $magic == "$release "* ]] || fail "Wrong module release for $module: $magic"
done
echo 'PASS: installed camera, IPU7, Bluetooth and loopback modules match the target kernel'
echo 'PASS: pre-reboot file checks complete; boot-time hardware validation remains'
