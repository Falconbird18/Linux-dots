#!/usr/bin/env python3
"""Tablet-only touch rings and non-consuming three-finger workspace swipes."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


class Swipe:
    def __init__(self):
        self.points = {}
        self.origins = {}
        self.started = 0
        self.blocked = False

    def event(self, event, now):
        kind, key = event['kind'], event['id']
        if kind == 'down':
            if not self.points:
                self.started = now
                self.blocked = False
            self.points[key] = (event['x'], event['y'])
            if len(self.points) == 3:
                self.origins = self.points.copy()
                self.blocked |= now - self.started > 0.3
            elif len(self.points) > 3:
                self.blocked = True
        elif kind in ('up', 'cancel'):
            self.points.pop(key, None)
            if self.origins:
                self.blocked = True
            if not self.points:
                self.origins.clear()
        elif kind == 'move' and key in self.points:
            self.points[key] = (event['x'], event['y'])
            if len(self.points) == 3 and not self.blocked and self.origins:
                deltas = [(p[0] - self.origins[k][0], p[1] - self.origins[k][1])
                          for k, p in self.points.items()]
                dx = sum(p[0] for p in deltas) / 3
                dy = sum(p[1] for p in deltas) / 3
                if now - self.started > 1.2:
                    self.blocked = True
                elif abs(dx) >= 0.12 and abs(dx) >= 2 * abs(dy) and all(
                        x * dx > 0 and abs(x) >= 0.07 for x, _ in deltas):
                    self.blocked = True  # Exactly one switch until all fingers lift.
                    return '+1' if dx < 0 else '-1'
        return None


def main():
    path = Path(os.environ['XDG_RUNTIME_DIR']) / 'surface11-touch-events.sock'
    path.unlink(missing_ok=True)
    receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    receiver.bind(str(path))
    os.chmod(path, 0o600)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    swipe = Swipe()
    try:
        while True:
            event = json.loads(receiver.recv(4096))
            print(json.dumps(event), flush=True)
            direction = swipe.event(event, time.monotonic())
            if direction:
                # Plugin suppresses events while the secure session lock is active.
                result = subprocess.run(['hyprctl', 'eval',
                                         'hl.dispatch(hl.dsp.focus({workspace="' + direction + '"}))'],
                                        text=True, capture_output=True, timeout=3)
                if result.returncode or result.stdout.strip() != 'ok':
                    print('Workspace swipe failed', file=sys.stderr, flush=True)
    finally:
        receiver.close()
        path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
