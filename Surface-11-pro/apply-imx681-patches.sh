#!/usr/bin/env bash
set -euo pipefail

# Apply Sony IMX681 front-camera patches for the Surface Pro 11.
# Adapts the driver to the V4L2 API in the target kernel source.

KERNEL_DIR="${1:-$(pwd)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/patches}"

cd "$KERNEL_DIR"

echo "[+] Kernel source: $KERNEL_DIR"
echo "[+] Patch directory: $PATCH_DIR"

# 1. Check the kernel source tree.
if [[ ! -f drivers/media/pci/intel/ipu-bridge.c ||
      ! -f drivers/media/i2c/Kconfig ||
      ! -f drivers/media/i2c/Makefile ]]; then
    echo "[-] This does not look like the expected kernel source directory."
    exit 1
fi

# 2. Apply the IMX681 driver patch if the driver is missing.
if [[ -f drivers/media/i2c/imx681.c ]]; then
    echo "[+] IMX681 driver already exists; skipping driver patch."
elif [[ -f "$PATCH_DIR/imx681.patch" ]]; then
    echo "[+] Applying IMX681 driver patch..."
    patch -p1 --forward < "$PATCH_DIR/imx681.patch"
else
    echo "[-] Missing driver and patch: $PATCH_DIR/imx681.patch"
    exit 1
fi

# 3. Adapt the driver callback signatures to the kernel's V4L2 API.
echo "[+] Checking IMX681 V4L2 API compatibility..."

python - <<'PY'
from pathlib import Path
import re
import shutil
import sys

path = Path("drivers/media/i2c/imx681.c")
text = path.read_text()
updated = text

# Match either the old four-argument signature or the corrected
# three-argument signature. Whitespace and line wrapping are flexible.
functions = [
    (
        "imx681_set_pad_format",
        re.compile(
            r"(static\s+int\s+imx681_set_pad_format\s*"
            r"\(\s*struct\s+v4l2_subdev\s*\*\s*sd\s*,\s*)"
            r"(?:const\s+struct\s+v4l2_subdev_client_info\s*"
            r"\*\s*ci\s*,\s*)?"
            r"(struct\s+v4l2_subdev_state\s*\*\s*state\s*,\s*)"
            r"(struct\s+v4l2_subdev_format\s*\*\s*fmt\s*\))"
        ),
    ),
    (
        "imx681_get_selection",
        re.compile(
            r"(static\s+int\s+imx681_get_selection\s*"
            r"\(\s*struct\s+v4l2_subdev\s*\*\s*sd\s*,\s*)"
            r"(?:const\s+struct\s+v4l2_subdev_client_info\s*"
            r"\*\s*ci\s*,\s*)?"
            r"(struct\s+v4l2_subdev_state\s*\*\s*state\s*,\s*)"
            r"(struct\s+v4l2_subdev_selection\s*\*\s*sel\s*\))"
        ),
    ),
]

for name, pattern in functions:
    matches = list(pattern.finditer(updated))

    if len(matches) != 1:
        print(
            f"[-] Expected exactly one recognizable {name} signature; "
            f"found {len(matches)}."
        )
        print("[-] No changes have been written by this step.")
        sys.exit(1)

    match = matches[0]
    signature = match.group(0)

    if "v4l2_subdev_client_info" in signature:
        replacement = match.group(1) + match.group(2) + match.group(3)
        updated = (
            updated[:match.start()]
            + replacement
            + updated[match.end():]
        )
        print(f"[+] Removed obsolete client-info argument from {name}.")
    else:
        print(f"[+] {name} already has the compatible signature.")

if updated != text:
    backup = path.with_suffix(".c.bak")

    if not backup.exists():
        shutil.copy2(path, backup)
        print(f"[+] Backup created: {backup}")
    else:
        print(f"[+] Existing backup preserved: {backup}")

    path.write_text(updated)
    print("[+] V4L2 callback signatures updated.")
else:
    print("[+] No driver changes needed.")
PY

# 4. Ensure the IMX681 Kconfig entry exists.
if grep -q '^config VIDEO_IMX681$' drivers/media/i2c/Kconfig; then
    echo "[+] Kconfig already contains VIDEO_IMX681."
elif [[ -f "$PATCH_DIR/Kconfig.patch" ]]; then
    echo "[+] Applying Kconfig patch..."
    patch -p1 --forward < "$PATCH_DIR/Kconfig.patch"
else
    echo "[-] Missing Kconfig entry and patch: $PATCH_DIR/Kconfig.patch"
    exit 1
fi

# 5. Ensure the IMX681 Makefile entry exists.
if grep -q 'CONFIG_VIDEO_IMX681.*imx681\.o' drivers/media/i2c/Makefile; then
    echo "[+] Makefile already contains the IMX681 entry."
elif [[ -f "$PATCH_DIR/Makefile.patch" ]]; then
    echo "[+] Applying Makefile patch..."
    patch -p1 --forward < "$PATCH_DIR/Makefile.patch"
else
    echo "[-] Missing Makefile entry and patch: $PATCH_DIR/Makefile.patch"
    exit 1
fi

# 6. Register IMX681 with the Intel IPU bridge.
BRIDGE_FILE="drivers/media/pci/intel/ipu-bridge.c"

if grep -q 'IPU_SENSOR_CONFIG("SONY0681"' "$BRIDGE_FILE"; then
    echo "[+] IMX681 IPU bridge entry already exists."
else
    echo "[+] Adding IMX681 to the IPU bridge sensor table..."

    python - "$BRIDGE_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

anchor = '\tIPU_SENSOR_CONFIG("OVTID858", 2, 540000000, 270000000),'
entry = '\tIPU_SENSOR_CONFIG("SONY0681", 1, 969600000),'

count = text.count(anchor)

if count != 1:
    sys.exit(
        f"[-] Expected exactly one OV13858 sensor-table entry; "
        f"found {count}. No bridge changes were made."
    )

text = text.replace(anchor, anchor + "\n" + entry, 1)
path.write_text(text)

print("[+] Inserted IMX681 entry after OV13858.")
PY
fi

# 7. Verify all required source changes.
echo
echo "[+] Verifying IMX681 integration..."

DRIVER="drivers/media/i2c/imx681.c"

[[ -f "$DRIVER" ]] || {
    echo "[-] IMX681 driver source is missing."
    exit 1
}

grep -q '^config VIDEO_IMX681$' drivers/media/i2c/Kconfig || {
    echo "[-] VIDEO_IMX681 is missing from Kconfig."
    exit 1
}

grep -q 'CONFIG_VIDEO_IMX681.*imx681\.o' drivers/media/i2c/Makefile || {
    echo "[-] IMX681 is missing from the I2C Makefile."
    exit 1
}

grep -q 'IPU_SENSOR_CONFIG("SONY0681"' "$BRIDGE_FILE" || {
    echo "[-] SONY0681 is missing from the IPU bridge sensor table."
    exit 1
}

if grep -q 'v4l2_subdev_client_info' "$DRIVER"; then
    echo "[-] The driver still references v4l2_subdev_client_info."
    echo "[-] Inspect the source before building."
    exit 1
fi

echo "[+] All IMX681 source integration checks passed."
echo "[+] No kernel build was started by this script."
