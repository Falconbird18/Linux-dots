#!/usr/bin/env python3
"""Test camera visibility using an isolated PipeWire/WirePlumber instance."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BACKEND = 'libcamera_input.__SB_.PC00.I2C5.CAMF'
PUBLIC = 'surface11-camera-front'


def monitor_graph(env):
    process = subprocess.Popen(['pw-dump', '-m'], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    try:
        output, _ = process.communicate(timeout=0.75)
    except subprocess.TimeoutExpired:
        process.terminate()
        output, _ = process.communicate(timeout=3)
    state = {}
    decoder = json.JSONDecoder()
    remaining = output.lstrip()
    while remaining:
        entries, end = decoder.raw_decode(remaining)
        remaining = remaining[end:].lstrip()
        for obj in entries:
            if obj.get('info') is None:
                state.pop(obj['id'], None)
            else:
                state[obj['id']] = obj
    return [obj.get('info', {}).get('props', {}).get('node.name')
            for obj in state.values() if obj['type'].endswith(':Node')]


def main():
    # All children share one PID namespace, so PipeWire can inspect their creds.
    # No host configuration or physical camera is used by this test.
    with tempfile.TemporaryDirectory(prefix='surface11-pw-') as temporary:
        directory = Path(temporary)
        (directory / 'conf').mkdir()
        scripts = directory / 'data/scripts'
        scripts.mkdir(parents=True)
        config = Path('/usr/share/wireplumber/wireplumber.conf').read_text()
        config += '\n' + (ROOT / 'wireplumber/90-surface11-camera.conf').read_text()
        config += '''
wireplumber.profiles = { main = {
  monitor.alsa = disabled
  monitor.bluez = disabled
  monitor.alsa-midi = disabled
  monitor.bluez-midi = disabled
  monitor.v4l2 = disabled
  monitor.libcamera = disabled
} }
'''
        (directory / 'conf/wireplumber.conf').write_text(config)
        (scripts / 'surface11-camera-policy.lua').write_text(
            (ROOT / 'wireplumber/surface11-camera-policy.lua').read_text())
        env = dict(os.environ, PIPEWIRE_RUNTIME_DIR=temporary,
                   WIREPLUMBER_CONFIG_DIR=str(directory / 'conf'),
                   WIREPLUMBER_DATA_DIR=f'{directory}/data:/usr/share/wireplumber')
        processes = []

        def start(command):
            process = subprocess.Popen(command, env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            return process

        try:
            start(['pipewire'])
            time.sleep(0.3)
            start(['wireplumber'])
            time.sleep(0.8)
            for name, role in [(BACKEND, 'SurfaceBackend'), (PUBLIC, 'Camera')]:
                start(['gst-launch-1.0', '-q', 'videotestsrc', 'is-live=true', '!',
                       'video/x-raw,width=640,height=480,framerate=30/1', '!',
                       'pipewiresink', 'mode=provide',
                       f'stream-properties=props,node.name={name},media.class=Video/Source,media.role={role}'])
            time.sleep(0.6)
            nodes = monitor_graph(env)
            assert BACKEND not in nodes, 'Native backend is visible to apps'
            assert PUBLIC in nodes, 'Public webcam was accidentally hidden'
            subprocess.run([
                'timeout', '5s', 'gst-launch-1.0', '-q', 'pipewiresrc',
                'client-properties=props,application.name=surface11-camera-relay',
                f'target-object={BACKEND}', 'num-buffers=3', '!',
                'video/x-raw,format=RGBx,width=640,height=480', '!', 'fakesink',
            ], env=env, check=True)
            print('PASS: apps see public webcam; native backend is private and relay capture works')
        finally:
            for process in reversed(processes):
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
