# Camera operation and recovery

Run commands from `Surface-11-pro/`. See [the setup guide](../README.md) first.

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
The rear mounting rotation is applied to the pixels.

The default `natural` profile applies a five-neighbor median to luminance only,
keeping the original luminance noise reduction while preserving color detail.
`balanced` preserves the previous all-plane median, and `detail` disables it.
[GStreamer's filter implementation](https://github.com/GStreamer/gst-plugins-good/blob/master/gst/videofilter/gstvideomedian.c)
confirms that `filtersize=5` is a five-neighbor cross, not a 5×5 kernel.

The PipeWire publishers copy the same pixels into shared-memory buffers for
portal and native clients. They open capture only while used and restart after
a prolonged capture stall. The nominal 30 fps route can repeat frames if physical
capture is slower.

## Changing image processing

Use `bash install-surface11.sh camera-quality natural` (or `balanced` / `detail`)
for a targeted update. It validates both pipeline descriptions, checks live feeds
before changing anything, saves the installed wrapper and existing profile override
under `$XDG_STATE_HOME/surface11-camera/quality-backups/` (default `~/.local/state/`),
and selects a private wrapper copy through one atomic, user-owned service drop-in.
The installed system wrapper and relay binary stay untouched; sudo is unnecessary.
A failed restart or live-image check restores the previous service drop-in and
restarts the original configuration. Keep the selected backup directory: it
contains the wrapper used by the service. Baseline failures leave the installed setup untouched.
No packages, modules, firmware, IPA files, device rules or WirePlumber policy change.
The chosen profile survives camera reinstalls through the service drop-in.

For manual recovery, restore the saved `quality.conf` to
`~/.config/systemd/user/surface11-cameras.service.d/80-surface11-quality.conf`
if the backup has `had-override`; otherwise remove only that managed drop-in.
Run `systemctl --user daemon-reload` and
`systemctl --user restart surface11-cameras.service` afterward.

WirePlumber's libcamera monitor and the raw IPU7 V4L2 devices are disabled on this supported Surface, so capture
runs in the camera services and apps see the processed public cameras. Its V4L2
monitor remains enabled for other webcams, with monitor copies of video42/43
disabled. USB webcams remain available. Raw `/dev/video0`–`/dev/video31` nodes
remain accessible for libcamera and low-level tools; applications that enumerate
all device files themselves can still list them. PipeWire/portal clients see the
two processed cameras. No portal permission scripts are replaced. Camera capture does not run
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

On November 18, 2026, `natural` was applied on the running
`7.3.2-surface11-camera1` kernel using the targeted user-service override.
Both cameras passed simultaneous PipeWire capture across two opens, followed by
separate V4L2 mmap and read captures with changing, nonuniform images. The manager
remained active with zero automatic restarts, and exactly two public routes were
visible. The initial immediate post-restart probe triggered rollback; the updater
now waits for route registration before capturing. Synthetic tests verify retained
luminance denoise, preserved small chroma features, range and rotation. Four
isolated updater tests cover success, baseline failure and restoration with or
without an existing override. This validates operation and the processing change;
color calibration and subjective scene quality remain unmeasured. The kernel,
drivers, firmware and installed system camera files were not changed in this run.


```sh
bash install-surface11.sh status
bash install-surface11.sh verify-boot
bash camera/setup-system-cameras.sh check
bash install-surface11.sh quality
bash install-surface11.sh undo-cameras
```

On November 6, 2026, the full live check passed on the original
`7.2.9-surface11-camera1` kernel with the updated services: changing images from
both cameras through PipeWire, V4L2 mmap and V4L2 read across two opens;
concurrent PipeWire clients; simultaneous front/rear capture; and held-buffer
integrity on both loopbacks. The relay stayed running without restarts. Bluetooth
was verified enabled at boot, detected in BlueZ and powered on. The relay now
accepts V4L2's normal `ENOENT` when its nonblocking event queue is drained;
a regression test covers this startup failure as well as genuine I/O errors.
Missing sensor properties/calibration still produce libcamera warnings; these
checks validate capture, not calibrated color or every application's behavior.
The complete 7.3.2 kernel/module build passed, including the kernel's x86
instruction decoder and randomized instruction sanity checks. The series also
passes fresh-archive and repeat-application tests. IMX681,
OV13858, IPU bridge, INT3472, SoundWire quirks, Intel PCIe Bluetooth and the
patched loopback source compile against the new headers. The patched loopback
also passes full module linkage against the 7.3.2 symbol table with the expected
`7.3.2-surface11-camera1` vermagic. A new-kernel boot still needs validation on
the device.

`verify-boot` authenticates with sudo and performs read-only checks: EFI image
and configuration match the completed build, boot entry paths/options, retained
working fallback, Secure Boot state, initramfs release/NVMe drivers, and installed
camera/Bluetooth module releases. It does not change the boot default or reboot.

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
bash tests/check-kernel-patches.sh "$HOME/surface-kernel-build/linux-7.3.2.tar.xz"
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

