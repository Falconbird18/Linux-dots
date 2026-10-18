# Surface Pro 11 standard webcam setup

Use `bash install-surface11.sh` as the main entry point; it handles kernel and
userspace phases. The commands below are lower-level camera-only helpers.

The patched kernel and native libcamera/PipeWire stack already stream both sensors.
The remaining compatibility layer exposes processed video as ordinary V4L2 cameras:

- `/dev/video42`: **Surface Front Camera**
- `/dev/video43`: **Surface Rear Camera**

Quit Discord from its tray menu and close all camera apps before installing.
Run as the logged-in desktop user, **not** with sudo in front of the whole script:

```bash
bash setup-system-cameras.sh install
bash setup-system-cameras.sh check
```

The installer requests sudo for packages, DKMS, module options, udev rules and the
relay executable. Per-user services start at login. The old Discord test launcher
is removed; use the normal app launcher. The module loads at boot. Kernel rebuilds
run DKMS again when this setup is installed. No kernel source patches are added by
this setup. Existing sensor patches are still required.

The relay keeps a black placeholder while idle. A v4l2loopback client-usage event
starts the named native PipeWire source, and idle releases it. Fixed 640×480 YUYV
at 30 fps is the initial compatibility target, not a sensor quality improvement.
Apps can still list native/raw devices too; choose the two names above. Native
PipeWire users and V4L2 apps share processed capture through PipeWire. OS camera
permissions still apply. A virtual device is not a guarantee that every app works.

The upstream Canonical relay is pinned to commit
`7ecae8774f3f6c9f8eb0c8d15e9ee03cdff62a96`. The installer adapts its event number to
the current v4l2loopback API and corrects its splash-object null check. It compiles
that userspace relay locally, rather than installing unpinned binaries. Driver
source: https://github.com/v4l2loopback/v4l2loopback
Relay source: https://gitlab.com/canonical-mainstream/v4l2-relayd

## Validation and current limits

Both native cameras delivered frames concurrently before this setup was written.
The relay compiles against the installed GStreamer libraries. The loopback module also builds against `7.2.9-surface11-custom`. Shell syntax is
checked. End-to-end loopback capture, idle release, reopen, reboot and Discord/Zen
still require running the installer and testing on the host. Do not treat this as
a verified finished fix until those checks pass. `check` temporarily captures raw frames, rejects uniform black placeholders,
and deletes those buffers on exit. Aim both cameras at a lit scene. It does not
verify identity, orientation or image quality; inspect the preview too. After capture finishes, check that the native PipeWire sources
return to suspended with `wpctl status` / `pw-cli info NODE_ID`.

If setup fails, preserve its output and inspect:

```bash
systemctl --user status surface11-camera-{front,rear}.service
journalctl --user -u surface11-camera-front -u surface11-camera-rear -n 80
```

If another app already loaded v4l2loopback, setup stops rather than unloading an
active module. Close its users and unload it before retrying. Device numbers 42
and 43 must be free. DKMS needs the matching configured kernel build tree, and
Secure Boot must permit loading the resulting module.

## Undo

```bash
bash setup-system-cameras.sh undo
```

This removes the services and this setup's boot configuration. Reboot to remove
the idle virtual devices; packages and native camera support remain installed.

## Stale DKMS records after a custom rebuild

The kernel build script removes the previous module directory. DKMS can still
report v4l2loopback as installed afterward, causing `dkms autoinstall` to skip it.
`ensure-camera-module.sh` now refreshes the module index and force-installs the
specific module if it is missing. Kernel rebuilds also force compilation against
the new build tree even when the release string is unchanged. Rerun `install`
after pulling this correction; no additional sensor patch or reboot is needed
unless module loading itself reports an error.

## Malformed labels from an earlier installer revision

The old module-options line quoted each item in `card_label` separately. The
kernel retained embedded quotes in the resulting device names. The corrected
line quotes the whole comma-separated value once. The installer recognizes only
these specific malformed Surface labels and reloads their idle loopback module
after writing the corrected configuration. An in-use module is never force-unloaded.

## Pipeline parser and startup readiness correction

The relay parses its input and idle descriptions before attaching an appsink.
A trailing shorthand caps declaration had no following element, so parsing failed
with `no element "video"`. Both descriptions now end in `identity`, leaving a
real output pad for the relay. Install parses all three exact descriptions for
both cameras first, without activating camera capture. The check waits up to ten
seconds for each loopback to report capture mode and the expected format, and
reports a missing frame file cleanly instead of producing a Python traceback.

## Pixel-aspect-ratio negotiation correction

The host's detailed V4L2 log reports square-pixel output formats with
`pixel-aspect-ratio=1/1`. The previous appsrc caps omitted that field: they
intersected the reported formats but were not a subset, so GStreamer's acceptance
check rejected them. Input conversion, appsrc and idle descriptions now declare
the ratio consistently. The pre-install validator checks that declaration.

Reinstall also resets systemd's failed/start-limit state before restarting both
relays. The pinned relay's teardown now guards absent input objects and event
watches, keeping secondary cleanup warnings from obscuring the actual error.
Validation reproduced the old rejection and accepted the new caps against the
formats from the real host log. The adjusted relay compiles and a forced early
output failure exits without null-object cleanup warnings. Actual capture still
needs the updated installed services and the master installer's frame checks.

## App test findings and remaining work

The front camera works in Discord, Zen and GNOME Camera; rear capture failed in
those app tests. After Discord and all camera apps were fully closed, a separate
30-frame native PipeWire rear-camera test passed again. The earlier logs showed
raw rear capture failing with `Device or resource busy`. This is consistent with
an app holding the raw IPU7 capture node, rather than a missing sensor driver.

`Built-in Front Camera` / `Built-in Back Camera` are native libcamera nodes;
`Surface Front Camera` / `Surface Rear Camera` are the standard loopback devices.
The former appearing in a website report does not verify the loopback route.
Legacy apps may also list an IPU7 raw capture device. This revision does not hide
that raw node: changing its permissions would also affect the native camera
broker running as the same desktop user. Choose the named Surface cameras and
avoid selecting IPU7 while testing. Elimination of this extra legacy entry remains
unresolved; do not advertise universal app compatibility yet.

The previous `io-mode=rw` workaround was invalid: GStreamer accepts the option
but its V4L2 output path only logs `implement write()` without writing frames.
The direct writer described below replaces that workaround. The capture check requires at least 30 complete frames, nonuniform image data,
and at least three distinct images among the final 30 frames. It cannot establish
which physical camera the app selected or validate a video call.

640x480 is the current compatibility baseline, not a sensor maximum. Grain and
colour problems still need sensor/ISP calibration. No global horizontal flip is
introduced: apps/websites can mirror their preview. Check readable text in a
saved photo or at the remote end of a call before changing captured pixels.


## Direct loopback writer correction

The output description now ends in an appsink. `loopback-writer.h`, compiled into
the pinned relay, configures the loopback as 640×480 YUYV at 30 fps and writes each
complete frame through the driver's file-I/O API. It packs padded image rows,
retries interrupted writes, and reports failed or short writes as pipeline errors.
This avoids both the unimplemented GStreamer rw output and the previous mmap
queue/dequeue path. Client-usage events use the same open descriptor, preserving
the on-demand native source and idle black placeholder.

Keep `loopback-writer.h` alongside the scripts. After closing camera apps, rerun
the main installer to rebuild and install the relay:

```bash
bash install-surface11.sh cameras
```

The installer still checks changing, nonuniform frames from both cameras. Camera
capture, idle release, reopening and application compatibility require host testing;
compilation and pipeline parsing alone cannot verify those behaviors.

Run the hardware-independent regression checks with:

```bash
bash tests/check-relay.sh
```

These use real GStreamer frame buffers and simulated V4L2 calls to check packed
and padded rows, configuration failures, interrupted writes, short writes, write
errors and invalid frame formats. Dependencies are the same GStreamer development
libraries, compiler and Python GI bindings used by the installer. No service or
system configuration is changed by this test.
