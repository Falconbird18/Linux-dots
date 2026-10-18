#!/usr/bin/env bash
# Apply locally downloaded Sony IMX681 patches to a Linux kernel source tree.
# Run from the kernel source root, e.g.:
#   cd ~/surface-kernel-build/linux-7.2.9
#   bash ../apply-imx681-patches.sh
#
# Expected patch files:
#   ~/surface-kernel-build/patches/imx681.patch
#   ~/surface-kernel-build/patches/Kconfig.patch
#   ~/surface-kernel-build/patches/Makefile.patch
#   ~/surface-kernel-build/patches/ipu-bridge.patch
#
# The supplied files may be quoted-printable encoded. This script normalizes
# them first, then checks each patch before applying it.

set -euo pipefail

PATCH_DIR="${PATCH_DIR:-$HOME/surface-kernel-build/patches}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for f in imx681.patch Kconfig.patch Makefile.patch ipu-bridge.patch; do
    if [[ ! -s "$PATCH_DIR/$f" ]]; then
        echo "[-] Missing patch file: $PATCH_DIR/$f"
        exit 1
    fi
done

# Decode quoted-printable mail-body artifacts without changing ordinary diffs.
python3 - "$PATCH_DIR" "$TMP_DIR" <<'PYEOF'
from pathlib import Path
import quopri
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

for name in ("imx681.patch", "Kconfig.patch", "Makefile.patch", "ipu-bridge.patch"):
    raw = (src / name).read_bytes()
    decoded = quopri.decodestring(raw)
    if b"diff --git " not in decoded:
        raise SystemExit(f"[-] {name}: no valid unified git diff found after decoding")
    (dst / name).write_bytes(decoded)
    print(f"[+] Normalized {name}")
PYEOF

apply_or_verify() {
    local patch="$1"
    local target="$2"
    local marker="$3"

    if grep -Fq "$marker" "$target"; then
        echo "[+] $target already contains '$marker'; skipping patch."
        return 0
    fi

    echo "[+] Checking $patch..."
    if ! git apply --check "$TMP_DIR/$patch"; then
        echo "[-] Patch does not apply cleanly: $patch"
        echo "    No automatic fuzzing or forced application will be attempted."
        exit 1
    fi

    git apply "$TMP_DIR/$patch"
    grep -Fq "$marker" "$target" || {
        echo "[-] Patch applied but verification failed: $target lacks '$marker'"
        exit 1
    }
    echo "[+] Applied and verified $patch"
}

# The driver source itself.
if [[ -s drivers/media/i2c/imx681.c ]] &&
   grep -Fq 'SONY0681' drivers/media/i2c/imx681.c; then
    echo "[+] IMX681 driver already exists; skipping driver patch."
else
    if [[ -e drivers/media/i2c/imx681.c ]]; then
        echo "[-] imx681.c exists but SONY0681 support was not found; inspect it manually."
        exit 1
    fi
    echo "[+] Checking IMX681 driver patch..."
    git apply --check "$TMP_DIR/imx681.patch"
    git apply "$TMP_DIR/imx681.patch"
    grep -Fq 'SONY0681' drivers/media/i2c/imx681.c || {
        echo "[-] Driver patch applied but ACPI ID SONY0681 was not found."
        exit 1
    }
    echo "[+] IMX681 driver applied and verified."
fi

apply_or_verify Kconfig.patch drivers/media/i2c/Kconfig 'config VIDEO_IMX681'
apply_or_verify Makefile.patch drivers/media/i2c/Makefile 'CONFIG_VIDEO_IMX681) += imx681.o'

# Prefer the supplied bridge patch if it applies to this kernel revision.
# If it does not, insert the same sensor entry near the existing sensor table,
# but only if there is a unique, known anchor.
BRIDGE="drivers/media/pci/intel/ipu-bridge.c"
BRIDGE_ENTRY='IPU_SENSOR_CONFIG("SONY0681", 1, 969600000)'

if grep -Fq "$BRIDGE_ENTRY" "$BRIDGE"; then
    echo "[+] SONY0681 IPU bridge entry already present."
elif git apply --check "$TMP_DIR/ipu-bridge.patch" >/dev/null 2>&1; then
    git apply "$TMP_DIR/ipu-bridge.patch"
    grep -Fq "$BRIDGE_ENTRY" "$BRIDGE" || {
        echo "[-] Bridge patch applied but SONY0681 entry was not found."
        exit 1
    }
    echo "[+] Applied supplied IPU bridge patch."
else
    echo "[!] Supplied IPU bridge patch does not match this source revision."
    echo "[+] Attempting a guarded insertion beside the existing sensor entries..."
    python3 - "$BRIDGE" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
entry = 'IPU_SENSOR_CONFIG("SONY0681", 1, 969600000)'
anchors = [
    '\t/* Omnivision OV13B10 */',
    '\t/* Omnivision OV13858 */',
    '\tIPU_SENSOR_CONFIG("OVTID858", 2, 540000000, 270000000)',
]

found = [a for a in anchors if a in text]
if len(found) != 1:
    raise SystemExit(
        "[-] Could not identify exactly one known camera-table anchor. "
        "No bridge changes saved."
    )

anchor = found[0]
if anchor.startswith('\tIPU_SENSOR_CONFIG'):
    insertion = '\t/* Sony IMX681 */\n\t' + entry + ',\n'
else:
    insertion = '\t/* Sony IMX681 */\n\t' + entry + ',\n'

text = text.replace(anchor, insertion + anchor, 1)
path.write_text(text)
print("[+] Inserted SONY0681 bridge entry.")
PYEOF
fi

# Final verification.
grep -Fq 'SONY0681' drivers/media/i2c/imx681.c
grep -Fq 'config VIDEO_IMX681' drivers/media/i2c/Kconfig
grep -Fq 'CONFIG_VIDEO_IMX681) += imx681.o' drivers/media/i2c/Makefile
grep -Fq "$BRIDGE_ENTRY" "$BRIDGE"

echo
echo "[+] IMX681 source, Kconfig, Makefile, and IPU bridge changes verified."
echo "[!] This confirms source integration only; build and runtime camera support are not yet proven."
