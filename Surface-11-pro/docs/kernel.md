# Kernel and installation details

Run commands from `Surface-11-pro/`. See [the setup guide](../README.md) first.

The source archive is SHA-256 pinned to the digest in kernel.org's
[signed checksum list](https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc).
All kernel changes are local patches listed in `patches/series`. There are no
emailed patches downloaded during the build and no best-effort source rewrites.
Applying the series again verifies already-applied changes; unknown/partial
changes stop the build. `SURFACE11_BUILD_DIR` and `SURFACE11_BUILD_JOBS` can set
the build location and parallelism. The initial kernel configuration comes from
the running kernel so the machine's existing storage/network drivers are kept.

The build requires working sudo, internet access, a compiler toolchain, and
enough disk space for a full kernel build. Use a fully upgraded Arch system;
the installer deliberately does not perform an unattended full-system upgrade.
Secure Boot signing/enrollment must already be configured if Secure Boot is
enabled; this script does not manage signing keys.

## Bluetooth, camera repair, and kernel upgrade

The November 6, 2026 inspection found working Intel PCIe firmware and `hci0`,
but a disabled, stopped BlueZ service. `install` now installs BlueZ and Intel
firmware, loads `btintel_pcie`, unblocks Bluetooth, enables/starts BlueZ, powers
the controller on, and checks discovery. The kernel configuration explicitly
retains PCIe Bluetooth support. This does not erase pairings or reset the Wi-Fi
controller. To repair Bluetooth independently:

```sh
bash install-surface11.sh bluetooth
```

The repeated “ipu7” camera choices were 32 raw ISYS queues exposed by
WirePlumber's V4L2 monitor. The visibility policy matches the PCI device and
IPU7 identity instead of relying on raw video numbers. Repair it independently
without root or a kernel rebuild:

```sh
bash install-surface11.sh camera-policy
```

That repair was applied and verified on this Surface: only the two processed
camera routes remain in PipeWire. To migrate older separate front/rear relay
services to the shared-camera manager, run `cameras`; it also works on the
previous `7.2.9-surface11-camera1` kernel. The DKMS registration check consumes
the full status output so a pipe closing early cannot trigger duplicate module
registration on reruns. Installation needs sudo authentication.

```sh
bash install-surface11.sh cameras
bash install-surface11.sh kernel
```

The kernel source is pinned to **7.3.2**, the latest stable release listed by
kernel.org on November 6, 2026. Build and test scripts share the pin in
`kernel/version.env`. The six kernel patches include the sensor's
Kconfig/Makefile wiring in `imx681.patch`; the old separate wiring patches and
unused POWER0 definition were removed. No active input helpers or diagnostics
were deleted. The kernel archive digest is
`4bfe0afc57e80d6cde1f8266d5ed8d3734a8d77ebb1d0a54a00426add6377676`.

With build dependencies already installed, `kernel-build` performs the same
source verification, patching, configuration and full compilation without sudo
or changing boot files. Use the **same** `SURFACE11_BUILD_DIR` for `kernel-build`
and `kernel` to reuse the result. A kernel build alone does not install or boot
it. Reboot into the new entry yourself, then rerun `install` for camera setup.

Research: [kernel.org releases](https://www.kernel.org/),
[kernel source checksums](https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc),
[WirePlumber camera monitors](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/features.html),
[BlueZ configuration](https://github.com/bluez/bluez/blob/master/src/main.conf).

