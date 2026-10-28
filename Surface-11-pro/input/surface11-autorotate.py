#!/usr/bin/env python3
"""Debounced iio-sensor-proxy → Hyprland rotation, scoped to the internal panel."""
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time

TRANSFORMS = {'normal': 0, 'left-up': 1, 'bottom-up': 2, 'right-up': 3}
ORIENTATION = re.compile(r'(?:orientation changed: |orientation: )(normal|left-up|bottom-up|right-up)\b')


class Debounce:
    def __init__(self, settle=2.0, cooldown=4.0):
        self.settle, self.cooldown = settle, cooldown
        # SensorProxy reports orientation categories, not a tilt angle. Require
        # a deliberate hold rather than accepting a brief threshold crossing.
        self.pending = None
        self.since = self.last = float('-inf')

    def feed(self, value, now):
        if value != self.pending:
            self.pending, self.since = value, now

    def ready(self, now):
        return (self.pending is not None and now - self.since >= self.settle
                and now - self.last >= self.cooldown)


def hypr(*args):
    result = subprocess.run(['hyprctl', *args], text=True, capture_output=True, timeout=4)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def apply_rotation(panel, transform):
    # A partial monitor rule preserves refresh rate, scale, HDR, position and VRR.
    name = json.dumps(panel)
    reply = hypr('eval', f'hl.monitor({{output={name}, transform={transform}}}); '
                 'hl.config({input={'
                 f'touchdevice={{output={name}, transform={transform}}}, '
                 f'tablet={{output={name}, transform={transform}}}' + '}})')
    if not reply.strip() or any(line.strip() != 'ok' for line in reply.splitlines() if line.strip()):
        raise RuntimeError(f'Hyprland rejected rotation: {reply.strip()}')


def main():
    if not os.environ.get('HYPRLAND_INSTANCE_SIGNATURE'):
        raise SystemExit('Start from a Hyprland session.')
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    lock = (runtime / 'surface11-autorotate.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    debounce = Debounce()
    while not stopped:
        sensor = subprocess.Popen(['stdbuf', '-oL', 'monitor-sensor', '--accel'],
                                  stdout=subprocess.PIPE, env={**os.environ, 'LC_ALL': 'C'})
        try:
            os.set_blocking(sensor.stdout.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(sensor.stdout, selectors.EVENT_READ)
                buffer = b''
                reconcile = 0.0
                applied = None
                while not stopped and sensor.poll() is None:
                    for key, _ in selector.select(0.15):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            break
                        buffer += chunk
                        while b'\n' in buffer:
                            line, buffer = buffer.split(b'\n', 1)
                            match = ORIENTATION.search(line.decode(errors='replace'))
                            if match:
                                debounce.feed(TRANSFORMS[match[1]], time.monotonic())
                                reconcile = 0.0
                            elif b'orientation changed:' in line or b'Waiting for' in line or b'No accelerometer' in line:
                                debounce.pending = None
                    now = time.monotonic()
                    if (runtime / 'surface11-rotation-inhibited').exists():
                        # Unlocking must also wait for a fresh, stable hold.
                        debounce.since = now
                        applied = None
                        continue
                    if not debounce.ready(now) or now < reconcile:
                        continue
                    reconcile = now + 3.0
                    try:
                        monitors = json.loads(hypr('-j', 'monitors'))
                        panel = next((m for m in monitors if m['name'].startswith('eDP-')
                                      and not m.get('disabled', False) and m.get('dpmsStatus', True)), None)
                        if not panel:
                            applied = None
                            continue
                        desired = (panel['name'], debounce.pending)
                        if desired != applied or panel.get('transform') != debounce.pending:
                            apply_rotation(*desired)
                            applied = desired
                            debounce.last = now
                            print(f'Rotated {desired[0]} to transform {desired[1]}', flush=True)
                    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
                        print(f'Rotation deferred: {error}', flush=True)
        finally:
            sensor.terminate()
            try:
                sensor.wait(timeout=3)
            except subprocess.TimeoutExpired:
                sensor.kill()
                sensor.wait()
            sensor.stdout.close()
        debounce.pending = None
        for _ in range(30):
            if stopped:
                break
            time.sleep(0.1)


if __name__ == '__main__':
    main()
