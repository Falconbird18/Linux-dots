#!/usr/bin/env python3
"""Debounce Surface orientation from SensorProxy and apply it to Hyprland."""
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
INITIAL = re.compile(r'=== Has accelerometer \(orientation: ([\w-]+)(?:, tilt: ([\w-]+))?\)')
# Allow normal viewing angles; flat and missing/unknown tilt still fail closed.
ROTATION_TILTS = {'vertical', 'tilted-up', 'tilted-down'}


class SensorState:
    def __init__(self):
        self.orientation = self.tilt = None
        self.reported = False

    def feed(self, line):
        if match := INITIAL.fullmatch(line):
            self.orientation, self.tilt = match.groups()
            self.reported = True
        elif line.startswith('Accelerometer orientation changed: '):
            self.orientation = line.split(': ', 1)[1]
            self.reported = True
        elif line.startswith('Tilt changed: '):
            self.tilt = line.split(': ', 1)[1]
        elif line in {'--- Accelerometer disappeared', '=== No accelerometer'}:
            self.orientation = self.tilt = None
            self.reported = True
        elif line.startswith(('Waiting for ', '--- iio-sensor-proxy vanished')):
            self.orientation = self.tilt = None
            self.reported = False

    def transform(self):
        if self.tilt in ROTATION_TILTS:
            return TRANSFORMS.get(self.orientation)
        return None


class Debounce:
    def __init__(self, settle=1.0, cooldown=2.0):
        self.settle, self.cooldown = settle, cooldown
        self.pending = None
        self.since = 0.0
        self.last_applied = float('-inf')

    def feed(self, value, now):
        if value != self.pending:
            self.pending, self.since = value, now

    def ready(self, now):
        return (self.pending is not None and now - self.since >= self.settle
                and now - self.last_applied >= self.cooldown)

    def applied(self, now):
        self.last_applied = now


def hypr(*args):
    result = subprocess.run(['hyprctl', *args], text=True, capture_output=True, timeout=4)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def apply_rotation(panel, transform, rotate_panel):
    # A partial monitor rule inherits the configured mode, scale, position and color settings.
    name = json.dumps(panel)
    lua = f'hl.monitor({{output={name}, transform={transform}}}); ' if rotate_panel else ''
    lua += ('hl.config({input={'
            f'touchdevice={{output={name}, transform={transform}}}, '
            f'tablet={{output={name}, transform={transform}}}'
            '}})')
    reply = hypr('eval', lua)
    if reply.strip() != 'ok':
        raise RuntimeError(f'Hyprland rejected rotation: {reply.strip()}')


def reconcile_rotation(transform, applied):
    monitors = json.loads(hypr('-j', 'monitors'))
    panel = next((m for m in monitors if m['name'].startswith('eDP-')
                  and not m.get('disabled', False) and m.get('dpmsStatus', True)), None)
    if panel is None:
        return None
    desired = panel['name'], transform
    rotate_panel = panel.get('transform') != transform
    if rotate_panel or applied != desired:
        apply_rotation(*desired, rotate_panel)
        if rotate_panel:
            print(f'Rotated {desired[0]} to transform {desired[1]}', flush=True)
    return desired


def watch_sensor(sensor, inhibit, stopping):
    state = SensorState()
    debounce = Debounce()
    waiting_since = next_check = time.monotonic()
    last_tick = time.clock_gettime(time.CLOCK_BOOTTIME)
    applied = None
    buffer = b''
    with selectors.DefaultSelector() as selector:
        selector.register(sensor.stdout, selectors.EVENT_READ)
        while not stopping():
            events = selector.select(0.2)
            if stopping():
                return
            now = time.monotonic()
            tick = time.clock_gettime(time.CLOCK_BOOTTIME)
            if tick - last_tick > 1:
                # Require a new hold after suspend or a stalled event loop.
                debounce.feed(None, now)
            last_tick = tick
            inhibited = inhibit.exists()
            for key, _ in events:
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    raise RuntimeError('monitor-sensor closed its output')
                lines = (buffer + chunk).split(b'\n')
                buffer = lines.pop()
                for line in lines:
                    previous_state = state.orientation, state.tilt, state.reported
                    state.feed(line.decode(errors='replace').strip())
                    if (state.orientation, state.tilt, state.reported) != previous_state:
                        print(f'Sensor orientation={state.orientation}, tilt={state.tilt}, '
                              f'available={state.reported}', flush=True)
                    debounce.feed(None if inhibited else state.transform(), now)
            if state.reported:
                waiting_since = now
            elif now - waiting_since >= 30:
                raise RuntimeError('SensorProxy did not report accelerometer status')
            debounce.feed(None if inhibited else state.transform(), now)
            if not debounce.ready(now) or now < next_check:
                continue
            next_check = now + 0.5
            try:
                previous = applied
                applied = reconcile_rotation(debounce.pending, applied)
                if applied is not None and applied != previous:
                    debounce.applied(time.monotonic())
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
                applied = None
                print(f'Rotation deferred: {error}', flush=True)


def main():
    if not os.environ.get('HYPRLAND_INSTANCE_SIGNATURE'):
        raise SystemExit('Start from a Hyprland session.')
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    inhibit = runtime / 'surface11-rotation-inhibited'
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
    # SensorProxy owns the accelerometer. Direct HID sysfs reads can block the driver.
    with subprocess.Popen(['stdbuf', '-oL', 'monitor-sensor', '--accel'],
                          stdout=subprocess.PIPE, env={**os.environ, 'LC_ALL': 'C'}) as sensor:
        try:
            watch_sensor(sensor, inhibit, lambda: stopped)
        except RuntimeError as error:
            raise SystemExit(f'Auto-rotation waiting for sensor: {error}') from error
        finally:
            sensor.terminate()
            try:
                sensor.wait(timeout=3)
            except subprocess.TimeoutExpired:
                sensor.kill()


if __name__ == '__main__':
    main()
