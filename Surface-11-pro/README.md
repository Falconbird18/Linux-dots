# Intel Surface Pro 11 setup

This folder is a self-contained installer for the Intel Surface Pro 11 for
Business, SKU 2103, on Arch Linux or an Arch derivative using systemd-boot with
the EFI partition mounted at `/efi`. It does not support Snapdragon models,
other camera modules, GRUB, or other distributions. Copy the **entire folder**
to another matching device; paths and build directories are derived locally.

Run as the logged-in desktop user:

```sh
bash install-surface11.sh install
```

The first run builds Linux 7.2.9 with the local patches and installs
`7.2.9-surface11-camera1` as a separate boot option. Reboot into that entry and
run the same command again to install and check the cameras. The script never
reboots automatically. It preserves the original kernel's modules and boot
files. Keep the generated kernel source/build directory: DKMS uses it when
building v4l2loopback for this custom kernel.

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

## Folder layout

- `install-surface11.sh`: supported entry point for installation and recovery.
- `input/`: touch/tablet keyboard setup, Hyprland config and auto-rotation.
- `camera/`: camera setup, runtime helpers and maintained C sources.
- `kernel/`: kernel build, patch application and loopback module setup.
- `patches/`: pinned kernel/libcamera/loopback patches and ordered kernel series.
- `wireplumber/`: camera monitor configuration.
- `tests/`: hardware-free checks and explicit hardware diagnostics.

Keep these folders together. Build artifacts stay in the existing external
cache/build locations. Generated Python bytecode and the unused legacy relay
source-rewriting tools have been removed; current builds use the maintained C
source in `camera/`.

## Camera path

Both sensors produce raw Bayer data. A kernel driver alone does not make them
ordinary webcams. libcamera's simple pipeline performs demosaicing, automatic
exposure, and white balance. Each relay acquires its sensor directly with
GStreamer `libcamerasrc` through the **CPU software ISP**: on the tested machine the GPU path produced nearly uniform dark frames.
The matched libcamera IPA sidecar provides the IMX681 analogue-gain formula;
distro libraries are retained. No app-specific launchers or preload are needed.

On-demand relays provide packed 1280×720, 30 fps YUYV with square pixels and
limited-range BT.709 color metadata at:

| Device | Name | PipeWire source |
| --- | --- | --- |
| `/dev/video42` or `/dev/surface-front-camera` | Surface Front Camera | `surface11-camera-front` |
| `/dev/video43` or `/dev/surface-rear-camera` | Surface Rear Camera | `surface11-camera-rear` |

The relay requests 3200×1800 from the front ISP and 1920×1080 from the rear,
then scales to 720p with Lanczos filtering. This avoids the CPU ISP's tight
720p center crop and averages sensor noise without stretching the image.
The rear mounting rotation is applied to the pixels. A modest spatial median
filter reduces noise; set `Environment=SURFACE11_CAMERA_QUALITY=detail` in a
relay service override to disable it for comparison. The PipeWire publishers
copy these same pixels into shared-memory buffers for portal and native clients.
They open capture only while used and restart after a prolonged capture stall.
The nominal 30 fps route can repeat frames if physical capture is slower.

WirePlumber's libcamera monitor is disabled on this supported Surface, so capture
runs in the camera services and apps see the processed public cameras. Its V4L2
monitor remains enabled for other webcams, with monitor copies of video42/43
disabled. No portal permission scripts are replaced. Camera capture does not run
inside the audio session manager. A WirePlumber restart also restarts the relays
and publishers.

Version-sensitive parts stop rather than load an incompatible IPA. The tested
userspace is libcamera/libcamera-ipa 0.7.2, WirePlumber 0.5.18, PipeWire 1.6.10,
and v4l2loopback 0.15.4. The loopback source is checksum-verified and patched
in a separate `0.15.4.surface11.1` DKMS source directory; package-owned sources
are retained. The local patch tracks queued capture buffers, prevents the
file-I/O producer from overwriting app-held mmap buffers, and serializes read
copies and persists color-only format updates. The writer verifies the stored
format with `G_FMT`, rather than trusting the `S_FMT` echo. A 16-buffer capture
pool leaves room for normal apps to retain frames. When an app holds every mmap
buffer, incoming frames are dropped until it returns one. This fixes the observed GStreamer unqueued-buffer failure.
The installer replaces the indexed module for the target kernel and reloads it
only when the two managed devices are the only loopbacks. Other users must
release the devices before that reload can proceed.

The IPA builder requires libcamera 0.7.2 and records the exact installed package
versions. After a package upgrade, rerun the
installer; the startup guard falls back to the distro IPA until rebuilt, which
may degrade front-camera exposure if the distro still lacks its gain helper.

## Checks and recovery

```sh
bash install-surface11.sh status
bash camera/setup-system-cameras.sh check
bash install-surface11.sh quality
bash install-surface11.sh undo-cameras
```

For `check` and `quality`, uncover both lenses and use a lit, varied scene.
Checks capture in memory, wait for exposure warmup, reject uniform/frozen frames,
and exercise the public cameras across reopen through concurrent PipeWire
clients and separate V4L2 read/mmap captures. A retained-buffer hardware test
also verifies that mapped pixels do not change until the app returns them.
The route diagnostic connects through the ordinary PipeWire socket.
`undo-cameras` removes the managed bridge configuration and services, retaining
packages and kernel drivers. Reboot afterward to remove idle loopback devices.

Hardware-free checks (requires the installed development dependencies):

```sh
bash tests/check-relay.sh
python3 tests/check-relay-lifecycle.py
dbus-run-session -- python3 tests/check-publisher.py
bash tests/check-kernel-patches.sh "$HOME/surface-kernel-build/linux-7.2.9.tar.xz"
```

These cover packed/padded frame copies, write errors, color range conversion,
pixel rotation, noise filtering, gain-helper math, public camera routing,
concurrent ordinary/portal streams, idle/reopen, and patch application/repeat.
The relay lifecycle test compiles the maintained C source with synthetic input;
it requires no stale source cache or camera build.

Color accuracy and optical lens correction are deferred. No measured color
matrices, lens shading maps, or distortion models are installed. The quality
command reports exposure/clipping/change metrics rather than calibration error.
Compatibility tests cover the V4L2 and PipeWire interfaces; individual apps and a
fresh boot still need checking on each device. Apps requiring a fixed format
other than YUYV 720p may need format conversion.

The loopback driver permits one direct V4L2 capture owner at a time. Concurrent
apps should use PipeWire; a direct V4L2 app can make the PipeWire capture busy
until it releases the device, just as with an exclusive physical camera.

## Hyprland auto-rotation

The default `install` command also installs auto-rotation before any kernel build.
To install rotation independently of the camera/kernel setup, run from your
Hyprland session:

```sh
bash install-surface11.sh rotation
```

Requires modern Hyprland with Lua configuration at
`$XDG_CONFIG_HOME/hypr/hyprland.lua` (normally `~/.config/hypr/hyprland.lua`).
The installer installs `iio-sensor-proxy`, starts its system service, copies the
Python helper into `~/.local/lib/surface11/`, and installs a user systemd service.
It adds an idempotent startup hook to the Lua configuration and saves the original
as `hyprland.lua.before-surface11-rotation`. Run the installer again after replacing
that configuration with a fresh dotfiles copy. No camera-specific kernel is needed
for rotation; the running kernel must expose the accelerometer to IIO.

The daemon uses SensorProxy's orientation labels together with raw IIO gravity
readings sampled in a background thread (up to about six times per second). A rotation requires **at least 25°
of physical tilt from the position recorded at startup or the last successful
screen rotation**, continuously for two seconds, with a four-second cooldown.
Small movements do not move that reference, and falling below 25° cancels the
pending hold. Unlocking, resume and sensor recovery establish a new reference.
This angle is measured between gravity vectors, not against the bed or a camera:
rotation around gravity while the Surface is nearly flat may intentionally leave
the screen unchanged. The label must also indicate a different screen orientation;
25° of movement alone does not force a 90° screen turn.
Missing, ambiguous, stale (older than 1.5 seconds), or invalid raw accelerometer
readings keep the screen fixed
and produce a journal message; the script never falls back to sensitive label-only
rotation. Readings with acceleration far from gravity are rejected.
Duplicate readings cause no display update. It changes only the internal `eDP-*`
panel's transform, preserving resolution, refresh rate, scale, position, HDR and
VRR. Touchscreen and pen input receive the same transform and are bound to that
panel. These input defaults assume the Surface's built-in digitizers; if using an
external touchscreen or drawing tablet, configure its output/transform explicitly
with a per-device Hyprland rule. Existing per-device overrides for the Surface's
own digitizers must also be removed or updated to allow these defaults to apply.
Disabled or sleeping panels are skipped. Sensor process failures are retried, and
panel transforms are checked before applying a rotation, avoiding redundant
display updates. The service restarts on failures and prevents duplicate daemon instances.
Hyprland performs the display transition; this does not add an animated rotation
or guarantee a flicker-free modeset on every driver.

Temporarily lock the current orientation, then unlock:

```sh
touch "$XDG_RUNTIME_DIR/surface11-rotation-inhibited"
rm -f "$XDG_RUNTIME_DIR/surface11-rotation-inhibited"
```

Inspect or stop rotation:

```sh
systemctl --user status surface11-autorotate.service
journalctl --user -u surface11-autorotate.service -f
systemctl --user stop surface11-autorotate.service
```

To remove auto-start, remove the `SURFACE11_AUTOROTATE_BEGIN` through
`SURFACE11_AUTOROTATE_END` block from your Lua config and run
`systemctl --user disable --now surface11-autorotate.service`. Log out/in to
restore your configured display and input defaults.

Validation without changing the desktop:

```sh
python3 -m unittest discover -s tests -p 'test_autorotate.py'
```

On the Surface, run `monitor-sensor --accel` to verify all four orientations,
then check each corner with touch and pen in each orientation. Check movements below and above 25°, rapid
back-and-forth tilts, lock/unlock, suspend/resume, a Hyprland reload, a new login,
and an external monitor. Software tests cannot verify physical sensor mounting,
digitizer calibration, or the driver's modeset smoothness.

## Tablet keyboard and touch navigation

The default installer also runs `input/setup-touch.sh`. To apply just these changes:

```bash
bash Surface-11-pro/install-surface11.sh touch
```

This installs Squeekboard, Quickshell and build tools, enables the session-scoped
`surface11-touch` service, and maps the built-in touch and pen input to `eDP-1`.
Auto-rotation continues to manage their transforms. The service checks hardware
once per second, ignoring keyd virtual devices, power/volume buttons and
consumer-control interfaces. A usable typing keyboard disables tablet behavior;
folding the Surface cover also works when the session can query its switch.

In tablet mode:

- Squeekboard starts hidden and follows native Wayland text-input activation.
  Tap a text field to show it; leave text entry (tap outside or close the field)
  to hide it. Pressing Enter while the field retains focus may keep it open.
- The mouse cursor is hidden and the Dux dock stays visible. Reconnecting the
  keyboard restores the cursor and dock auto-hide, and stops the desktop keyboard.
- Small blue touch rings track contacts and fade when released. Their overlay
  has an empty input region, so it cannot capture taps or take keyboard focus.
- Swipe **three fingers left** for the next workspace, **right** for the previous
  workspace. Fingers must arrive together and move horizontally roughly 12% of
  the screen. Small movements, vertical swipes, pinches, and four-finger gestures
  do not switch workspaces. Each gesture switches once until all fingers lift.

The installer enables Squeekboard's required accessibility setting and sets a US
layout only if no input layouts exist. It also enables native Wayland IME v3 in
Chromium/Electron flag files, preserving other flags. Reopen those apps afterward.
Automatic text-field detection requires client support; XWayland and apps that
never expose Wayland text-input focus cannot request this keyboard. The old
forced-show launcher and shortcut are removed. Dux's secure lock screen uses its
own keyboard button beside the password field.

`input/touch-observer.cpp` is a small local Hyprland plugin. It only forwards
built-in touchscreen events to a private user-runtime socket; it never grabs raw
input devices or cancels/modifies Hyprland's touch events. A tablet-only Quickshell
process draws the rings and recognizes swipes. Applications still receive their
normal touch stream, including multi-finger input. Locked sessions do not forward
events or switch workspaces. The built-in **edge** workspace gesture remains
disabled because it previously broke taps on this Hyprland build.

The observer is compiled against installed Hyprland headers and rejects a
compositor/API hash mismatch. After upgrading Hyprland, log into the matching new
version and rerun the touch installer to rebuild it. Libraries are replaced
atomically so rerunning setup cannot truncate a loaded plugin. Build products
are installed under `~/.local/lib/surface11/`, outside this source folder. The
installer backs up Hyprland before adding the include and updates Dux through IPC.

Check `systemctl --user status surface11-touch.service`,
`journalctl --user -u surface11-touch.service`, `hyprctl plugin list`, and
`hyprctl configerrors`. `input/setup-touch.sh --configure-only` updates user files
and compiles the observer using already installed dependencies; the normal touch
command also installs missing packages. A configuration reload restarts the
helper so cursor, keyboard and feedback state follow the current hardware mode.

Hardware-free checks:

```sh
python3 -B -m unittest discover -s tests -p 'test_*.py'
qmllint -I /usr/lib/qt6/qml input/touch-effects.qml
```

On the actual Surface, test text-field entry/exit, ordinary taps, touch rings,
three-finger swipes, all orientations, keyboard reconnect, and lock/unlock.

References: [Squeekboard](https://world.pages.gitlab.gnome.org/Phosh/squeekboard/),
[Chromium Wayland input switches](https://chromium.googlesource.com/chromium/src/+/lkgr/ui/ozone/public/ozone_switches.cc),
and [Hyprland configuration](https://wiki.hypr.land/Configuring/Basics/Variables/).
