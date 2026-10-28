#!/usr/bin/env python3
"""Angle-gated, debounced Surface rotation using IIO and SensorProxy."""
import fcntl
import json
import math
import os
from pathlib import Path
import re
import queue
import selectors
import signal
import subprocess
import time
import threading

TRANSFORMS = {'normal': 0, 'left-up': 1, 'bottom-up': 2, 'right-up': 3}
ORIENTATION = re.compile(r'(?:orientation changed: |orientation: )(normal|left-up|bottom-up|right-up)\b')


class AngleGate:
    """Latch gravity at startup/rotation; never follow small movements by drifting."""
    def __init__(self, degrees=25.0):
        self.degrees = degrees
        self.reference = None

    def reset(self, vector=None):
        self.reference = vector

    def allows(self, vector):
        if self.reference is None:
            self.reset(vector)
            return False
        cosine = sum(a * b for a, b in zip(self.reference, vector))
        cosine /= math.hypot(*self.reference) * math.hypot(*vector)
        return math.degrees(math.acos(max(-1.0, min(1.0, cosine)))) + 1e-9 >= self.degrees


class Accelerometer:
    """Read calibrated SI values; refuse ambiguous devices or invalid samples."""
    def __init__(self, root=Path('/sys/bus/iio/devices')):
        devices = [p for p in root.glob('iio:device*')
                   if all((p / f'in_accel_{axis}_raw').exists() for axis in 'xyz')]
        if len(devices) != 1:
            raise RuntimeError(f'Expected one accelerometer, found {len(devices)}')
        self.path = devices[0]
        self.offsets = tuple(self.attribute(axis, 'offset', 0) for axis in 'xyz')
        self.scales = tuple(self.attribute(axis, 'scale') for axis in 'xyz')

    def attribute(self, axis, name, default=None):
        for filename in (f'in_accel_{axis}_{name}', f'in_accel_{name}'):
            path = self.path / filename
            if path.exists():
                return float(path.read_text())
        if default is not None:
            return default
        raise RuntimeError(f'Missing accelerometer {name}')

    def read(self):
        vector = tuple((self.attribute(axis, 'raw') + offset) * scale
                       for axis, offset, scale in zip('xyz', self.offsets, self.scales))
        # Strong acceleration and free fall are not reliable gravity measurements.
        if not all(math.isfinite(v) for v in vector) or not 7.35 <= math.hypot(*vector) <= 12.26:
            raise RuntimeError('Accelerometer sample is moving or invalid')
        return vector


def sample_gravity(samples):
    """Sysfs HID reads can block. Keep the IPC loop and shutdown responsive."""
    sensor = None
    while True:
        started = time.monotonic()
        try:
            if sensor is None:
                sensor = Accelerometer()
            vector, error = sensor.read(), None
        except (OSError, ValueError, RuntimeError) as exception:
            sensor = None
            vector, error = None, str(exception)
        # Timestamp the start: a stalled multi-axis read is not a fresh sample.
        sample = (started, vector, error)
        try:
            samples.get_nowait()
        except queue.Empty:
            pass
        samples.put_nowait(sample)
        time.sleep(0.15 if error is None else 3.0)


class Debounce:
    def __init__(self, settle=2.0, cooldown=4.0):
        self.settle, self.cooldown = settle, cooldown
        # The angle gate must remain open throughout this settling period.
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
    samples = queue.Queue(maxsize=1)
    threading.Thread(target=sample_gravity, args=(samples,), daemon=True).start()
    while not stopped:
        gate = AngleGate()
        last_sample = time.monotonic()
        vector = None
        warning_at = 0.0
        sensor = subprocess.Popen(['stdbuf', '-oL', 'monitor-sensor', '--accel'],
                                  stdout=subprocess.PIPE, env={**os.environ, 'LC_ALL': 'C'})
        try:
            os.set_blocking(sensor.stdout.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(sensor.stdout, selectors.EVENT_READ)
                buffer = b''
                orientation = None
                reconcile = 0.0
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
                                orientation = TRANSFORMS[match[1]]
                                reconcile = 0.0
                            elif b'orientation changed:' in line or b'Waiting for' in line or b'No accelerometer' in line:
                                orientation = None
                    now = time.monotonic()
                    error = None
                    try:
                        stamp, reading, error = samples.get_nowait()
                        if now - stamp <= 1.5 and reading is not None:
                            if now - last_sample > 1.5:
                                gate.reset()
                                debounce.feed(None, now)
                            vector, last_sample = reading, stamp
                        else:
                            vector = None
                    except queue.Empty:
                        pass
                    if vector is None or now - last_sample > 1.5:
                        debounce.feed(None, now)
                        gate.reset()
                        if now >= warning_at:
                            print(f'Angle check unavailable; keeping orientation: {error or "waiting for fresh gravity readings"}', flush=True)
                            warning_at = now + 30.0
                        continue
                    if (runtime / 'surface11-rotation-inhibited').exists():
                        gate.reset(vector)
                        debounce.feed(None, now)
                        continue
                    debounce.feed(orientation if gate.allows(vector) else None, now)
                    if not debounce.ready(now) or now < reconcile:
                        continue
                    reconcile = now + 3.0
                    try:
                        monitors = json.loads(hypr('-j', 'monitors'))
                        panel = next((m for m in monitors if m['name'].startswith('eDP-')
                                      and not m.get('disabled', False) and m.get('dpmsStatus', True)), None)
                        if not panel:
                            continue
                        desired = (panel['name'], debounce.pending)
                        if panel.get('transform') != debounce.pending:
                            apply_rotation(*desired)
                            debounce.last = now
                            gate.reset(vector)
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
