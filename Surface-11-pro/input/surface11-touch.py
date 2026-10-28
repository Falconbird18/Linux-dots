#!/usr/bin/env python3
"""Run the desktop input method only when no usable hardware keyboard exists."""
import fcntl
import os
from pathlib import Path
import signal
import shutil
import struct
import subprocess
import time


def typing_keyboard(device):
    # sysfs prints machine-word groups most significant first. Python's integer
    # also handles 32-bit groups. Ignore virtual keyd/OSK devices and hotkeys.
    if '/virtual/' in str(device.resolve()):
        return False
    bits = 0
    for word in (device / 'capabilities/key').read_text().split():
        bits = (bits << (struct.calcsize('L') * 8)) | int(word, 16)
    return all(bits & (1 << key) for key in (16, 28, 30, 44, 57))


def tablet_switch(root):
    for device in root.glob('event*/device'):
        try:
            if 'Surface POS Tablet Mode Switch' not in (device / 'name').read_text():
                continue
            with Path('/dev/input', device.parent.name).open('rb', buffering=0) as stream:
                state = bytearray(8)
                fcntl.ioctl(stream, 0x8008451B, state)  # EVIOCGSW(8); SW_TABLET_MODE=1
                return bool(int.from_bytes(state, os.sys.byteorder) & 2)
        except (OSError, ValueError):
            pass  # Seat ACLs may not expose the switch; detach detection still works.
    return False


def needs_keyboard(root=Path('/sys/class/input')):
    folded = tablet_switch(root)
    for device in root.glob('event*/device'):
        try:
            if typing_keyboard(device):
                name = (device / 'name').read_text()
                if folded and 'Microsoft Surface' in name:
                    continue
                return False
        except FileNotFoundError:
            continue  # Hot-unplug during enumeration.
    return True


def set_dock_tablet_mode(tablet):
    """Reveal the dock in tablet mode; auto-hide it with a typing keyboard."""
    try:
        result = subprocess.run(
            ['dms', 'ipc', 'call', 'dock', 'manualHide' if tablet else 'autoHide'],
            text=True, capture_output=True, timeout=4)
        expected = 'BAR_MANUAL_HIDE_SUCCESS' if tablet else 'BAR_AUTO_HIDE_SUCCESS'
        return result.returncode == 0 and expected in result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False


def set_cursor_mode(tablet):
    try:
        result = subprocess.run(['hyprctl', 'eval',
                                 'hl.config({cursor={invisible=' + ('true' if tablet else 'false') + '}})'],
                                text=True, capture_output=True, timeout=3)
        return result.returncode == 0 and result.stdout.strip() == 'ok'
    except (OSError, subprocess.TimeoutExpired):
        return False


def stop_process(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    child = None
    effects = None
    stopped = False
    dock_check = 0.0
    last_mode = None

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopped:
            wanted = needs_keyboard()
            # Dux may start after this service or restart during the session.
            # Retry failures, and reconcile once a minute after a successful call.
            now = time.monotonic()
            if wanted != last_mode:
                dock_check = 0.0
                last_mode = wanted
            if now >= dock_check:
                cursor_ok = set_cursor_mode(wanted)
                if set_dock_tablet_mode(wanted) and cursor_ok:
                    dock_check = now + 60
                else:
                    dock_check = now + 5
            if effects and effects.poll() is not None:
                effects = None
            if wanted and effects is None:
                effects = subprocess.Popen(['qs', '-p', str(Path(__file__).with_name('touch-effects.qml'))])
            elif not wanted and effects is not None:
                stop_process(effects)
                effects = None
            if not shutil.which('squeekboard'):
                time.sleep(1)
                continue
            if child and child.poll() is not None:
                print(f'Squeekboard exited: {child.returncode}', flush=True)
                child = None
            if wanted and child is None:
                # Squeekboard honors this setting even outside GNOME/Phosh.
                subprocess.run(['gsettings', 'set', 'org.gnome.desktop.a11y.applications',
                                'screen-keyboard-enabled', 'true'], check=True)
                child = subprocess.Popen(['squeekboard'])
                print('Tablet: desktop keyboard enabled', flush=True)
            elif not wanted and child is not None:
                stop_process(child)
                child = None
                print('Hardware keyboard: desktop keyboard disabled', flush=True)
            time.sleep(1)
    finally:
        stop_process(effects)
        stop_process(child)
        set_cursor_mode(False)


if __name__ == '__main__':
    main()
