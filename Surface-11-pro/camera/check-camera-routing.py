#!/usr/bin/env python3
"""Check the public PipeWire graph without opening either camera."""
import json
import subprocess

BACKENDS = {
    'libcamera_input.__SB_.PC00.I2C5.CAMF',
    'libcamera_input.__SB_.PC00.I2C3.CAMR',
}


def graph_snapshot():
    # Initial globals may arrive before WirePlumber applies permissions. Merge
    # monitor removals as well as additions instead of inspecting that race.
    process = subprocess.Popen(['pw-dump', '-r', 'pipewire-0', '-m'], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        output, error = process.communicate(timeout=1.5)
    except subprocess.TimeoutExpired:
        process.terminate()
        output, error = process.communicate(timeout=5)
    if not output.strip():
        raise RuntimeError(f'Cannot read PipeWire graph: {error}')
    decoder = json.JSONDecoder()
    remaining = output.lstrip()
    state = {}
    while remaining:
        entries, end = decoder.raw_decode(remaining)
        remaining = remaining[end:].lstrip()
        for obj in entries:
            if obj.get('info') is None:
                state.pop(obj['id'], None)
            elif obj['id'] in state:
                state[obj['id']]['info'].update(obj['info'])
            else:
                state[obj['id']] = obj
    return list(state.values())


def routing_errors(graph):
    nodes = [obj.get('info', {}).get('props', {}) for obj in graph
             if obj.get('type') == 'PipeWire:Interface:Node']
    errors = []
    for camera, number in [('front', 42), ('rear', 43)]:
        name = f'surface11-camera-{camera}'
        matches = [p for p in nodes if p.get('node.name') == name]
        if len(matches) != 1:
            errors.append(f'Expected one {name}, found {len(matches)}')
        elif matches[0].get('media.class') != 'Video/Source':
            errors.append(f'{name} is not a video source')
        duplicates = [p for p in nodes if p.get('api.v4l2.path') == f'/dev/video{number}']
        if len(duplicates) != 1:
            errors.append(f'Expected one public route for video{number}, found {len(duplicates)}')
    for props in nodes:
        if props.get('node.name') in BACKENDS:
            errors.append(f'Native backend exposed to ordinary apps: {props["node.name"]}')
    return errors


if __name__ == '__main__':
    graph = graph_snapshot()
    errors = routing_errors(graph)
    if errors:
        raise SystemExit('\n'.join(errors))
    print('PASS: exactly two shared camera routes; native backends are private')
