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
import sys


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


def show_keyboard():
    """Retry until Squeekboard owns its bus name; process start is not readiness."""
    try:
        result = subprocess.run(
            ['busctl', '--user', 'call', 'sm.puri.OSK0', '/sm/puri/OSK0',
             'sm.puri.OSK0', 'SetVisible', 'b', 'true'],
            capture_output=True, text=True, timeout=2)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def request_keyboard():
    if not needs_keyboard():
        raise SystemExit('The on-screen keyboard is only available in tablet mode.')
    request = Path(os.environ['XDG_RUNTIME_DIR']) / 'surface11-keyboard-show'
    request.touch(mode=0o600)
    subprocess.run(['systemctl', '--user', 'start', 'surface11-touch.service'], check=True)


def main():
    child = None
    stopped = False
    dock_check = 0.0
    last_mode = None
    show_pending = False
    request = Path(os.environ['XDG_RUNTIME_DIR']) / 'surface11-keyboard-show'

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
                if set_dock_tablet_mode(wanted):
                    dock_check = now + 60
                else:
                    dock_check = now + 5
            if request.exists():
                request.unlink(missing_ok=True)
                show_pending = wanted
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
                show_pending = True
                print('Tablet: desktop keyboard enabled', flush=True)
            elif not wanted and child is not None:
                child.terminate()
                try:
                    child.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                child = None
                show_pending = False
                print('Hardware keyboard: desktop keyboard disabled', flush=True)
            if child and show_pending and show_keyboard():
                show_pending = False
                print('Desktop keyboard shown', flush=True)
            time.sleep(1)
    finally:
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == '__main__':
    if sys.argv[1:] == ['--show']:
        request_keyboard()
    elif sys.argv[1:]:
        raise SystemExit('Usage: surface11-touch.py [--show]')
    else:
        main()
