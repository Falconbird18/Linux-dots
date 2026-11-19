# Tablet input and rotation

Run commands from `Surface-11-pro/`. See [the setup guide](../README.md) first.

## Hyprland auto-rotation

The default `install` command repairs Bluetooth and installs auto-rotation before any kernel build.
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

Both the default install and the `rotation` command also install
`input/81-surface11-accelerometer.rules` into `/etc/udev/rules.d/`, reload the
rules, apply them to the connected accelerometer, and restart SensorProxy before
starting auto-rotation. The rule matches only the Intel Surface Pro 11 for
Business and its `045E:0C9C` sensor hub. It sets accelerometer hysteresis to zero
to request continuous reports even while the tablet is stationary. With the
firmware's on-change reporting, the Surface SAM HID transport cannot fetch a
sample on demand: reads can time out and return bogus zeros, causing false
orientation changes and slow SensorProxy startup. Longer rotation delays alone
do not fix that failure. See the [Surface sensor driver investigation](https://github.com/linux-surface/linux-surface/issues/2160).
The rule is reapplied when the sensor appears at boot; rerunning the installer
repairs an existing installation without requiring a reboot. Administrator
access is required for the udev rule and system sensor service.

The daemon uses SensorProxy for orientation and tilt. This avoids direct HID
sysfs reads, which can stall on this Surface. A new orientation must be stable
for one second with a `vertical`, `tilted-up`, or `tilted-down` tilt before it
takes effect, allowing rotation at normal viewing angles. Face-up, face-down, undefined and
missing tilt readings hold the current orientation and cancel the pending hold.
After accepting a new orientation, the daemon waits at least two seconds
before accepting another, reducing back-and-forth rotations. SensorProxy's labels
do not provide an angle measurement to distinguish small persistent movements
across an orientation boundary. Sensor disconnects cancel pending
rotations, and the user service reconnects if the sensor stops responding at
startup. The same one-second hold applies on startup, after a detected suspend,
and after unlocking.

Only the active internal `eDP-*` panel is rotated. Touchscreen and pen input
receive the same transform and are bound to that panel. For external
touchscreens or tablets, use per-device Hyprland rules to set their output and
transform. The startup hook also resynchronizes rotation after a Hyprland
configuration reload while the service is running.
The journal records sensor orientation/tilt changes as well as applied rotations
so unexpected SensorProxy reports can be distinguished from display changes.

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
python3 -m unittest discover -s tests -p 'test_autorotation_install.py'
```

On the Surface, run `monitor-sensor --accel` to verify all four orientations,
then check each corner with touch and pen in each orientation. Check brief
tilts, face-up and face-down use, lock/unlock, suspend/resume, a Hyprland reload,
a new login, and an external monitor.

## Tablet keyboard and touch navigation

The default installer also runs `input/setup-touch.sh`. To apply just these changes:

```bash
bash install-surface11.sh touch
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
- The mouse cursor is hidden. Reconnecting the keyboard restores the cursor
  and stops the desktop keyboard. The Dux dock auto-hides in both modes.
- Subtle 20-pixel outline rings track contacts at 28% opacity and fade within
  140 ms when released. Their overlay
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
