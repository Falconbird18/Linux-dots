#!/bin/bash
set -euo pipefail

# Ensure script is run as normal user
if [ "$EUID" -eq 0 ]; then
    echo "[-] Please do NOT run this script as root. Run as a normal user; it will prompt for sudo when needed."
    exit 1
fi

CAMERA_MODULE_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ensure-camera-module.sh"

KERNEL_VERSION="7.2.9"
CUSTOM_SUFFIX="-surface11-custom"
KERNEL_RELEASE="${KERNEL_VERSION}${CUSTOM_SUFFIX}"

# --- Paths ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$HOME/surface-kernel-build"
KERNEL_DIR="$WORK_DIR/linux-7.2.9"
PATCH_DIR="$SCRIPT_DIR/patches"

# Your ESP is mounted at /efi
ESP="/efi"

echo "=== [0/11] Cleaning up previous kernel installation ==="
# Clean both possible places
sudo rm -f /boot/vmlinuz-linux-surface11 \
           /boot/initramfs-linux-surface11.img \
           /boot/System.map-linux-surface11 \
           /boot/config-linux-surface11 2>/dev/null || true

sudo rm -f "$ESP/vmlinuz-linux-surface11" \
           "$ESP/initramfs-linux-surface11.img" \
           "$ESP/System.map-linux-surface11" \
           "$ESP/config-linux-surface11" 2>/dev/null || true

sudo rm -f "$ESP/loader/entries/surface11-custom.conf" 2>/dev/null || true

if [ -d "/lib/modules/$KERNEL_RELEASE" ]; then
    sudo rm -rf "/lib/modules/$KERNEL_RELEASE"
    echo "[+] Removed old module directory: /lib/modules/$KERNEL_RELEASE"
fi

echo "=== [1/11] Installing build dependencies ==="
sudo pacman -S --needed base-devel git bc pahole cpio libelf ncurses wget tar xz zstd python

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=== [2/11] Downloading Linux Kernel v$KERNEL_VERSION ==="
MAJOR_VERSION=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VERSION}.x/linux-$KERNEL_VERSION.tar.xz"
if [ ! -f "linux-$KERNEL_VERSION.tar.xz" ]; then
    wget -c "$KERNEL_URL"
fi
if [ ! -d "linux-$KERNEL_VERSION" ]; then
    echo "[*] Extracting kernel source..."
    tar -xf "linux-$KERNEL_VERSION.tar.xz"
fi
cd "linux-$KERNEL_VERSION"

echo "=== [3/11] Applying correct Surface Pro 11 SoundWire ghost-RT1320 quirk ==="
python3 - << 'PYEOF'
import re, sys

filepath = "drivers/soundwire/dmi-quirks.c"
with open(filepath, "r") as f:
    content = f.read()

if "microsoft_sp11_intel" in content and "0x000030025d132000" in content:
    print("[+] Correct Surface Pro 11 quirk already present – nothing to do.")
    sys.exit(0)

remap_table = r'''
/*
 * The Microsoft Surface Pro 11 (Intel) describes its single physical RT1320
 * amplifier twice on link 0, as two _ADR entries differing only in SDCA class
 * id and sharing the same unique id. Only the class 1 entry enumerates; the
 * class 0 entry is a ghost.
 *
 * Matched on the product SKU rather than the product name.
 */
static const struct adr_remap microsoft_sp11_intel[] = {
	/* ghost rt1320 on link0 */
	{
		0x000030025d132000ull,
		0x0000000000000000ull
	},
	{}
};
'''

if "static const struct dmi_system_id adr_remap_quirk_table" not in content:
    print("[-] Could not find adr_remap_quirk_table")
    sys.exit(1)

content = content.replace(
    "static const struct dmi_system_id adr_remap_quirk_table",
    remap_table + "\nstatic const struct dmi_system_id adr_remap_quirk_table",
    1
)

dmi_entry = r'''
	/* LNL devices – Surface Pro 11 (Intel) */
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),
			DMI_EXACT_MATCH(DMI_PRODUCT_SKU,
					"Surface_Pro_11th_Edition_With_Intel_For_Business_2103"),
		},
		.driver_data = (void *)microsoft_sp11_intel,
	},
'''

pattern = r'(static const struct dmi_system_id adr_remap_quirk_table\[\] = \{.*?)(\n\s*\{\s*\},?\s*\n\};)'
m = re.search(pattern, content, re.DOTALL)
if not m:
    print("[-] Could not locate end of adr_remap_quirk_table")
    sys.exit(1)

content = content[:m.end(1)] + dmi_entry + content[m.start(2):]

with open(filepath, "w") as f:
    f.write(content)

print("[+] Correct Surface Pro 11 SoundWire quirk injected successfully.")
PYEOF

touch drivers/soundwire/dmi-quirks.c


echo "=== [4/11] Applying INT3472 POWER1 camera fix ==="
python3 - <<'PYEOF'
import sys
from pathlib import Path

header = Path("include/linux/platform_data/x86/int3472.h")
source = Path("drivers/platform/x86/intel/int3472/discrete.c")

if not header.is_file() or not source.is_file():
    sys.exit("[-] INT3472 source files not found; refusing to continue.")

h = header.read_text()
c = source.read_text()

# If every part of the fix is already present, leave the files untouched.
if (
    "INT3472_GPIO_TYPE_POWER1" in h
    and 'case INT3472_GPIO_TYPE_POWER1:' in c
    and '*con_id = "dvdd";' in c
    and c.count("case INT3472_GPIO_TYPE_POWER1:") >= 3
):
    print("[+] INT3472 POWER1 fix already present.")
    sys.exit(0)

# Refuse to modify a partially patched or unexpected source tree.
if (
    "INT3472_GPIO_TYPE_POWER1" in h
    or "INT3472_GPIO_TYPE_POWER1" in c
    or "INT3472_GPIO_TYPE_POWER0" in h
):
    sys.exit(
        "[-] Partial or unexpected INT3472 fix detected. "
        "Inspect the source files before rebuilding."
    )

def replace_once(text, old, new, description):
    count = text.count(old)
    if count != 1:
        sys.exit(
            f"[-] Expected exactly one match for {description}, "
            f"found {count}. No files have been written."
        )
    return text.replace(old, new, 1)

# 1. Define POWER0 and POWER1 in the public header.
h_new = replace_once(
    h,
    "#define INT3472_GPIO_TYPE_STROBE\t\t\t\t0x02\n",
    "#define INT3472_GPIO_TYPE_STROBE\t\t\t\t0x02\n"
    "#define INT3472_GPIO_TYPE_POWER0\t\t\t\t0x07\n"
    "#define INT3472_GPIO_TYPE_POWER1\t\t\t\t0x08\n",
    "GPIO type definitions",
)

# 2. Map POWER1 to the sensor's dvdd supply.
c_new = replace_once(
    c,
    '\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n'
    '\t\t*con_id = "avdd";\n'
    '\t\t*gpio_flags = GPIO_ACTIVE_HIGH;\n'
    '\t\tbreak;\n',
    '\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n'
    '\t\t*con_id = "avdd";\n'
    '\t\t*gpio_flags = GPIO_ACTIVE_HIGH;\n'
    '\t\tbreak;\n'
    '\tcase INT3472_GPIO_TYPE_POWER1:\n'
    '\t\t*con_id = "dvdd";\n'
    '\t\t*gpio_flags = GPIO_ACTIVE_HIGH;\n'
    '\t\tbreak;\n',
    "POWER1 dvdd supply mapping",
)

# 3. Document the two GPIO type codes.
c_new = replace_once(
    c_new,
    " * 0x02 Strobe\n",
    " * 0x02 Strobe\n"
    " * 0x07 Power 0\n"
    " * 0x08 Power 1\n",
    "GPIO type documentation",
)

# 4. Allow POWER1 through GPIO resource handling.
c_new = replace_once(
    c_new,
    "\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n"
    "\tcase INT3472_GPIO_TYPE_DOVDD:\n"
    "\tcase INT3472_GPIO_TYPE_HANDSHAKE:\n"
    "\t\tgpio = skl_int3472_gpiod_get_from_temp_lookup",
    "\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n"
    "\tcase INT3472_GPIO_TYPE_POWER1:\n"
    "\tcase INT3472_GPIO_TYPE_DOVDD:\n"
    "\tcase INT3472_GPIO_TYPE_HANDSHAKE:\n"
    "\t\tgpio = skl_int3472_gpiod_get_from_temp_lookup",
    "GPIO resource handling",
)

# 5. Register POWER1 as a regulator.
c_new = replace_once(
    c_new,
    "\t\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n"
    "\t\t\tsecond_sensor = int3472->quirks.avdd_second_sensor;\n"
    "\t\t\tfallthrough;\n"
    "\t\tcase INT3472_GPIO_TYPE_DOVDD:\n"
    "\t\tcase INT3472_GPIO_TYPE_HANDSHAKE:\n"
    "\t\t\tret = skl_int3472_register_regulator",
    "\t\tcase INT3472_GPIO_TYPE_POWER_ENABLE:\n"
    "\t\t\tsecond_sensor = int3472->quirks.avdd_second_sensor;\n"
    "\t\t\tfallthrough;\n"
    "\t\tcase INT3472_GPIO_TYPE_POWER1:\n"
    "\t\tcase INT3472_GPIO_TYPE_DOVDD:\n"
    "\t\tcase INT3472_GPIO_TYPE_HANDSHAKE:\n"
    "\t\t\tret = skl_int3472_register_regulator",
    "POWER1 regulator registration",
)

# Write only after every expected source fragment has been validated.
header.write_text(h_new)
source.write_text(c_new)

print("[+] INT3472 POWER1 camera fix applied.")
PYEOF

touch drivers/platform/x86/intel/int3472/discrete.c
touch include/linux/platform_data/x86/int3472.h


# [5/11] Apply OV13858 camera power, IPU bridge, and rotation fixes
echo "=== [5/11] Applying OV13858 camera fixes ==="

OV_FILE="drivers/media/i2c/ov13858.c"
BRIDGE_FILE="drivers/media/pci/intel/ipu-bridge.c"
BRIDGE_ENTRY='IPU_SENSOR_CONFIG("OVTID858", 2, 540000000, 270000000)'
ROTATION_PRODUCT="Surface Pro for Business 11th Edition with Intel"


# --- 5a. Apply or verify the OV13858 power patch ---
echo "[+] Checking OV13858 power patch..."

PATCH_MARKERS=(
    "ov13858_supply_names"
    "static int ov13858_power_on("
    "static int ov13858_power_off("
    "devm_regulator_bulk_get"
    "devm_gpiod_get_optional"
    "DEFINE_RUNTIME_DEV_PM_OPS(ov13858_pm_ops"
    ".pm = pm_ptr(&ov13858_pm_ops)"
)

PRESENT=0
for marker in "${PATCH_MARKERS[@]}"; do
    if grep -Fq "$marker" "$OV_FILE"; then
        ((PRESENT += 1))
    fi
done

if (( PRESENT == ${#PATCH_MARKERS[@]} )); then
    echo "[+] All OV13858 power-patch markers are present; skipping patch."
elif (( PRESENT == 0 )); then
    echo "[+] OV13858 power patch is absent; downloading it..."

    PATCH_DIR="$(mktemp -d)"
    trap 'rm -rf "$PATCH_DIR"' EXIT

    curl --fail --location --retry 3 \
        "https://lore-kernel.gnuweeb.org/linux-media/20260831130312.26296-1-lsa.uz@pm.me/raw" \
        -o "$PATCH_DIR/ov13858-power.eml"

    git mailinfo "$PATCH_DIR/ov13858-power.msg" \
        "$PATCH_DIR/ov13858-power.patch" \
        < "$PATCH_DIR/ov13858-power.eml" >/dev/null

    if [[ ! -s "$PATCH_DIR/ov13858-power.patch" ]]; then
        echo "[-] OV13858 patch extraction failed."
        exit 1
    fi

    echo "[+] Checking whether the patch applies..."
    git apply --check "$PATCH_DIR/ov13858-power.patch"

    echo "[+] Applying OV13858 power patch..."
    git apply "$PATCH_DIR/ov13858-power.patch"

    rm -rf "$PATCH_DIR"
    trap - EXIT

    # Verify that all expected changes now exist.
    for marker in "${PATCH_MARKERS[@]}"; do
        if ! grep -Fq "$marker" "$OV_FILE"; then
            echo "[-] Power-patch verification failed: missing $marker"
            exit 1
        fi
    done

    echo "[+] OV13858 power patch applied and verified."
else
    echo "[-] OV13858 driver appears partially patched."
    echo "    Found $PRESENT of ${#PATCH_MARKERS[@]} expected markers."
    echo "    Refusing to reapply the patch automatically."
    echo "    Inspect drivers/media/i2c/ov13858.c before proceeding."
    exit 1
fi

# --- 5b. Add the IPU bridge sensor entry, if missing ---
echo "[+] Checking IPU bridge entry..."

if ! grep -Fq "$BRIDGE_ENTRY" "$BRIDGE_FILE"; then
    python3 - <<'PYEOF'
from pathlib import Path
import sys

path = Path("drivers/media/pci/intel/ipu-bridge.c")
text = path.read_text()

entry = 'IPU_SENSOR_CONFIG("OVTID858", 2, 540000000, 270000000)'
anchor = '\t/* Omnivision OV13B10 */'

if text.count(anchor) != 1:
    sys.exit("[-] Could not find a unique OV13B10 anchor in ipu-bridge.c.")

text = text.replace(
    anchor,
    '\t/* Omnivision OV13858 */\n'
    '\t' + entry + ',\n'
    + anchor,
    1,
)
path.write_text(text)
print("[+] IPU bridge entry inserted.")
PYEOF
else
    echo "[+] IPU bridge entry already present."
fi


# --- 5c. Add/fix the Surface Pro 11 camera rotation quirk ---
echo "[+] Checking Surface Pro 11 camera rotation quirk..."

python3 - <<'PYEOF'
from pathlib import Path
import re
import sys

path = Path("drivers/media/pci/intel/ipu-bridge.c")
text = path.read_text()

anchor = "static const struct dmi_system_id upside_down_sensor_dmi_ids[] = {"
if text.count(anchor) != 1:
    sys.exit("[-] Could not find a unique upside-down sensor DMI table.")

start = text.index(anchor) + len(anchor)
end = text.index("\n};", start)
table = text[start:end]

product = "Surface Pro for Business 11th Edition with Intel"
terminator = "\t{} /* Terminating entry */"

entry_pattern = re.compile(
    r'\t\{\s*'
    r'\.matches\s*=\s*\{\s*'
    r'DMI_EXACT_MATCH\(DMI_SYS_VENDOR,\s*"Microsoft Corporation"\),\s*'
    r'DMI_EXACT_MATCH\(DMI_PRODUCT_NAME,\s*'
    r'"Surface Pro for Business 11th Edition with Intel"\),\s*'
    r'\},\s*'
    r'\.driver_data\s*=\s*"OVTID858",\s*'
    r'\},',
    re.S
)

# Remove any existing copy of this exact entry from the table.
table, count = entry_pattern.subn("", table)

# Require exactly one terminating entry.
if table.count(terminator) != 1:
    sys.exit("[-] Could not find a unique DMI terminator; no changes saved.")

# Insert immediately before the terminator.
entry = '''\t{
\t\t.matches = {
\t\t\tDMI_EXACT_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),
\t\t\tDMI_EXACT_MATCH(DMI_PRODUCT_NAME,
\t\t\t\t\t"Surface Pro for Business 11th Edition with Intel"),
\t\t},
\t\t.driver_data = "OVTID858",
\t},
'''

table = table.replace(terminator, entry + terminator, 1)
text = text[:start] + table + text[end:]
path.write_text(text)

print("[+] Surface Pro rotation entry is now before the DMI terminator.")
PYEOF

# Verify the entry is inside the table and before its terminator.
python3 - <<'PYEOF'
from pathlib import Path
import sys

text = Path("drivers/media/pci/intel/ipu-bridge.c").read_text()
anchor = "static const struct dmi_system_id upside_down_sensor_dmi_ids[] = {"
start = text.index(anchor)
end = text.index("\n};", start)
table = text[start:end]

product = "Surface Pro for Business 11th Edition with Intel"
terminator = "{} /* Terminating entry */"

if table.count(product) != 1:
    sys.exit("[-] Expected exactly one Surface Pro rotation entry.")
if table.count(terminator) != 1:
    sys.exit("[-] Expected exactly one DMI terminator.")
if table.index(product) > table.index(terminator):
    sys.exit("[-] Rotation entry is still after the terminator.")

print("[+] Rotation entry and terminator ordering verified.")
PYEOF

# --- 5d. Verify the resulting source ---
grep -Fq "$BRIDGE_ENTRY" "$BRIDGE_FILE" || {
    echo "[-] IPU bridge entry verification failed."
    exit 1
}

grep -Fq "$ROTATION_PRODUCT" "$BRIDGE_FILE" || {
    echo "[-] Camera rotation quirk verification failed."
    exit 1
}

grep -q 'ov13858_supply_names' "$OV_FILE" || {
    echo "[-] OV13858 supply definitions were not found after patching."
    exit 1
}

trap - EXIT

echo "[+] IPU bridge entry and rotation quirk verified."
echo "[!] The rotation fix sets metadata to 180 degrees; not every application"
echo "    automatically rotates captured pixels."

# --- 5e. Apply local Sony IMX681 patches ---
echo "=== [5e] Applying Sony IMX681 front-camera patches ==="

(
    cd "$KERNEL_DIR"
    PATCH_DIR="$PATCH_DIR" bash "$SCRIPT_DIR/apply-imx681-patches.sh"
)

echo "=== [6/11] Preparing Kernel Configuration ==="
if [ -f .config ]; then
    echo "[+] Existing .config found, keeping current configuration."
elif [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > .config
    echo "[+] Loaded running kernel config from /proc/config.gz"
else
    make defconfig
    echo "[!] /proc/config.gz not found, falling back to defconfig"
fi

scripts/config --enable CONFIG_STAGING
scripts/config --enable CONFIG_VIDEO_INTEL_IPU7
scripts/config --module CONFIG_VIDEO_IMX681
scripts/config --enable CONFIG_VIDEO_INTEL_IPU7_ISYS
scripts/config --disable CONFIG_RUST
scripts/config --set-str CONFIG_LOCALVERSION "$CUSTOM_SUFFIX"

scripts/config --enable CONFIG_SOUNDWIRE
scripts/config --enable CONFIG_SOUNDWIRE_INTEL
scripts/config --module CONFIG_SND_SOC_SOF_INTEL_LNL || true
scripts/config --module CONFIG_SND_SOC_RT1320_SDW || true
scripts/config --module CONFIG_SND_SOC_SOF_SOUNDWIRE || true

make olddefconfig

if ! grep -q '^CONFIG_VIDEO_IMX681=m$' .config; then
    echo "[-] CONFIG_VIDEO_IMX681 is not enabled as a module."
    echo "    Check the driver's Kconfig dependencies and kernel configuration."
    exit 1
fi

echo "[+] IMX681 will be built as a kernel module."

echo "=== [7/11] Incremental compile ==="
# Force rebuild of the changed SoundWire file
rm -f drivers/soundwire/dmi-quirks.o drivers/soundwire/dmi-quirks.o.cmd \
      drivers/soundwire/built-in.a drivers/soundwire/modules.order 2>/dev/null || true

echo "[*] Compiling (incremental – only changed objects will be rebuilt)..."
make -j$(nproc)

echo "=== [8/11] Installing modules ==="
sudo make modules_install

echo "=== [9/11] Installing kernel image to ESP ($ESP) ==="
ACTUAL_KERNEL_RELEASE=$(make -s kernelrelease)
echo "[*] Actual kernelrelease: $ACTUAL_KERNEL_RELEASE"

# Keep the standard-camera bridge available after a custom kernel rebuild.
# This builds an external module; it does not patch the kernel source.
if [[ -f /etc/modules-load.d/surface11-camera.conf ]]; then
    command -v dkms >/dev/null || { echo "[-] Camera bridge requires DKMS."; exit 1; }
    bash "$CAMERA_MODULE_HELPER" "$ACTUAL_KERNEL_RELEASE" rebuild
fi

# Make sure ESP is accessible
if [ ! -d "$ESP" ]; then
    echo "[-] ESP directory $ESP does not exist or is not mounted!"
    exit 1
fi

sudo cp -v arch/x86/boot/bzImage "$ESP/vmlinuz-linux-surface11"
sudo cp -v System.map           "$ESP/System.map-linux-surface11"
sudo cp -v .config              "$ESP/config-linux-surface11"

echo "=== [10/11] Generating initramfs ==="
if command -v dracut &>/dev/null; then
    echo "[*] Using dracut..."
    sudo dracut --force "$ESP/initramfs-linux-surface11.img" "$ACTUAL_KERNEL_RELEASE"
elif command -v mkinitcpio &>/dev/null; then
    echo "[*] Using mkinitcpio..."
    sudo mkinitcpio -k "$ACTUAL_KERNEL_RELEASE" -g "$ESP/initramfs-linux-surface11.img"
else
    echo "[-] Neither dracut nor mkinitcpio found."
    exit 1
fi

echo "=== [11/11] Creating systemd-boot entry ==="
sudo mkdir -p "$ESP/loader/entries"

ROOT_PARTUUID=$(findmnt -n -o PARTUUID /)
if [ -z "$ROOT_PARTUUID" ]; then
    echo "[-] Could not determine root PARTUUID"
    exit 1
fi

ENTRY_FILE="$ESP/loader/entries/surface11-custom.conf"

sudo tee "$ENTRY_FILE" > /dev/null <<EOF
title   Linux Surface11 Custom ($KERNEL_VERSION)
linux   /vmlinuz-linux-surface11
initrd  /initramfs-linux-surface11.img
options root=PARTUUID=$ROOT_PARTUUID rw
EOF

echo
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo
echo "Kernel:     $ESP/vmlinuz-linux-surface11"
echo "Initramfs:  $ESP/initramfs-linux-surface11.img"
echo "Modules:    /lib/modules/$ACTUAL_KERNEL_RELEASE"
echo "Boot entry: $ENTRY_FILE"
echo
echo "Entry contents:"
sudo cat "$ENTRY_FILE"
echo
echo "Reboot now. You should see 'Linux Surface11 Custom' in the boot menu."
echo
echo "After booting into it, verify with:"
echo "  aplay -l"
echo "  ls /sys/bus/soundwire/devices/"
echo "  dmesg | grep -iE 'soundwire|rt1320|sof'"




# Standard V4L2 camera setup (run as the desktop user after reboot).
# Native cameras are processed by libcamera/PipeWire and exposed by on-demand
# loopback relays; no app-specific preload or alternate Discord launcher.
#   bash "$(dirname -- "${BASH_SOURCE[0]}")/setup-system-cameras.sh" install
#   bash "$(dirname -- "${BASH_SOURCE[0]}")/setup-system-cameras.sh" check
#   bash "$(dirname -- "${BASH_SOURCE[0]}")/setup-system-cameras.sh" undo
