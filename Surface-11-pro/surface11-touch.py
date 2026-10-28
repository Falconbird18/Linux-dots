#!/usr/bin/env python3
"""Run the desktop input method only when no usable hardware keyboard exists."""
import fcntl
import os
from pathlib import Path
import signal
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


def main():
    child = None
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopped:
            wanted = needs_keyboard()
            if child and child.poll() is not None:
                print(f'Squeekboard exited: {child.returncode}', flush=True)
                child = None
            if wanted and child is None:
                child = subprocess.Popen(['squeekboard'])
                print('Tablet: desktop keyboard enabled', flush=True)
            elif not wanted and child is not None:
                child.terminate()
                try:
                    child.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                child = None
                print('Hardware keyboard: desktop keyboard disabled', flush=True)
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
    main()
