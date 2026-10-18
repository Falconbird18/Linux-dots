#!/usr/bin/env python3
# Managed by surface11-camera. Check the graph visible to an ordinary app.
import json
import subprocess
import sys
import time

BACKENDS = {
    'libcamera_input.__SB_.PC00.I2C5.CAMF',
    'libcamera_input.__SB_.PC00.I2C3.CAMR',
}


def routing_errors(objects):
    nodes = [obj.get('info', {}).get('props', {}) for obj in objects
             if obj.get('type') == 'PipeWire:Interface:Node']
    errors = []
    for camera, number, label in [('front', 42, 'Surface Front Camera'),
                                  ('rear', 43, 'Surface Rear Camera')]:
        matches = [p for p in nodes if p.get('node.name') == f'surface11-camera-{camera}']
        if len(matches) != 1:
            errors.append(f'Expected one published {label}; found {len(matches)}.')
            continue
        props = matches[0]
        if (props.get('media.class') != 'Video/Source' or props.get('media.role') != 'Camera'
                or props.get('api.v4l2.path') != f'/dev/video{number}'
                or props.get('node.description') != label):
            errors.append(f'{label} does not publish the expected shared webcam.')
        copies = [p for p in nodes if p.get('api.v4l2.path') == f'/dev/video{number}'
                  and p.get('media.class') == 'Video/Source']
        if len(copies) != 1:
            errors.append(f'{label} has duplicate PipeWire capture nodes.')
    if any(p.get('node.name') in BACKENDS for p in nodes):
        errors.append('Native Surface backends are still visible to apps; check the WirePlumber policy.')
    return errors


def visible_graph():
    # Unrestricted clients can receive the initial registry before WirePlumber
    # applies per-object permissions. Observe removals as well as the snapshot.
    with subprocess.Popen(['pw-dump', '-m'], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as process:
        try:
            output, error = process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            process.terminate()
            output, error = process.communicate(timeout=3)
        if process.returncode not in (0, -15):
            raise RuntimeError(error.strip() or 'pw-dump failed')
    state = {}
    decoder = json.JSONDecoder()
    remaining = output.lstrip()
    while remaining:
        updates, end = decoder.raw_decode(remaining)
        remaining = remaining[end:].lstrip()
        for obj in updates:
            if obj.get('info') is None:
                state.pop(obj['id'], None)
                continue
            previous = state.setdefault(obj['id'], {'id': obj['id']})
            previous['type'] = obj.get('type', previous.get('type'))
            info = previous.setdefault('info', {})
            props = info.setdefault('props', {})
            props.update(obj['info'].get('props', {}))
    return list(state.values())


def main():
    for attempt in range(15):
        try:
            errors = routing_errors(visible_graph())
        except (subprocess.SubprocessError, json.JSONDecodeError, RuntimeError, OSError) as exc:
            errors = [f'Cannot inspect PipeWire routing: {exc}']
        if not errors:
            print('PASS: apps see one shared Surface front/rear pair; native backends are private.')
            return 0
        if attempt < 14:
            time.sleep(1)
    for error in errors:
        print(f'FAIL: {error}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
