# Intel Surface Pro 11 setup

For the **Intel Surface Pro 11 for Business, SKU 2103**, running Arch Linux
with systemd-boot and the EFI partition at `/efi`. Snapdragon models are unsupported.
Run commands from this folder as your desktop user; privileged steps request sudo.

## Everyday maintenance

| Task | Command | Effect |
| --- | --- | --- |
| Inspect setup | `bash install-surface11.sh status` | Read-only hardware/service status |
| Measure cameras | `bash install-surface11.sh quality` | Capture both public feeds; no settings changed |
| Adjust camera processing | `bash install-surface11.sh camera-quality natural` | Small, checked update with automatic rollback |
| Restore previous camera processing | `bash install-surface11.sh camera-quality balanced` | Original luminance and color filtering |
| Repair tablet input | `bash install-surface11.sh touch` | Keyboard, gestures and touch feedback |
| Repair rotation | `bash install-surface11.sh rotation` | SensorProxy and Hyprland rotation |
| Repair Bluetooth | `bash install-surface11.sh bluetooth` | BlueZ and controller setup |

A working camera does **not** need a kernel rebuild or the full camera installer
to adjust image processing. `camera-quality` keeps the kernel, drivers, IPA,
resolution, formats, routing and publishers in place. It briefly restarts only
the camera manager and its publishers. Quit camera apps first; both lenses must
show a lit, varied scene for the before/after checks.

The `natural` profile keeps the existing luminance noise reduction and preserves
small color details by skipping the extra chroma median filter. `balanced` is
the original processing; `detail` disables median filtering entirely and may
show more noise. These are processing choices, not sensor calibration.

## First installation

Copy this entire folder, including its subfolders, to a matching device:

```sh
bash install-surface11.sh install
```

This installs Bluetooth/tablet support and builds the pinned custom kernel if
needed. Reboot into **Linux Surface11 Cameras**, then run the same command again
for camera installation. It never reboots automatically or changes the boot default.
Use a fully upgraded Arch system with working sudo, build tools and disk space.
Secure Boot signing must already be handled if enabled.

## Custom kernel

The source pin and checksum live in `kernel/version.env`; Surface configuration
overrides live in `kernel/surface11.config`; ordered patches live in `patches/series`.
The base configuration comes from the running kernel to retain its drivers.

```sh
bash install-surface11.sh kernel-build  # compile only; dependencies must exist
bash install-surface11.sh kernel        # compile and install a separate boot entry
bash install-surface11.sh verify-boot   # read-only installed-file checks; sudo
```

`SURFACE11_BUILD_DIR` sets the build/cache location and `SURFACE11_BUILD_JOBS`
sets parallelism. By default an existing matching installed build tree is reused,
otherwise the cache is `~/surface-kernel-build`. Use the same location for build
and install. Boot another kernel before rebuilding the same release.

**Keep the installed kernel's build tree.** `/usr/lib/modules/<release>/build`
points to it and DKMS needs it for the camera loopback module. On the current
machine that tree is in `surface-kernel-build/` inside this folder. It is ignored
by Git, but is active infrastructure: do not delete or move it as cleanup.
Older versioned boot entries and the distro kernel remain available as fallbacks.

## Layout and detailed guides

| Location | Purpose |
| --- | --- |
| `install-surface11.sh` | Supported command dispatcher; start here |
| `kernel/`, `patches/` | Pinned kernel, config, build/install and driver patches |
| `camera/`, `wireplumber/` | Camera capture, processing, sharing and visibility |
| `input/`, `bluetooth/` | Tablet and Bluetooth setup |
| `tests/` | Hardware-free regression checks and explicit live diagnostics |
| `docs/` | Detailed operation, verification and recovery |

- [Kernel installation and patch details](docs/kernel.md)
- [Camera architecture, tests and recovery](docs/camera.md)
- [Tablet input and auto-rotation](docs/tablet.md)

Hardware-free camera checks: `bash tests/check-relay.sh` and
`python3 tests/check-relay-lifecycle.py`. Full camera repair is
`bash install-surface11.sh cameras`; reserve it for installation or actual faults.
