#!/usr/bin/env python3
"""Test camera visibility using an isolated PipeWire/WirePlumber instance."""
import json
import hashlib
import importlib.util
import shlex
import sys
sys.dont_write_bytecode = True
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
        # Use the real stock portal permission manager, including its Camera
        # interest. The libcamera SPA node advertises Camera despite monitor
        # rules requesting SurfaceBackend; the old fixture missed this.
        stock = Path('/usr/share/wireplumber/scripts/client/find-portal-access.lua').read_text()
        spec = importlib.util.spec_from_file_location('portal_override', ROOT / 'prepare-camera-portal.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        portal = stock if '--unpatched' in sys.argv else module.prepare(stock)
        portal += '''
SimpleEventHook {
  name = "test/select-portal",
  before = "client/find-portal-access",
  after = "client/find-config-access",
  interests = { EventInterest { Constraint { "event.type", "=", "select-access" } } },
  execute = function (event)
    if event:get_subject ():get_property ("application.name") == "surface11-test-portal" then
      event:set_data ("permission-manager", portal_pm)
    end
  end,
}:register ()
'''
        (scripts / 'client').mkdir()
        (scripts / 'client/find-portal-access.lua').write_text(portal)
        inspector = directory / 'inspect-permissions'
        flags = shlex.split(subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'libpipewire-0.3'], text=True))
        subprocess.run(['cc', str(ROOT / 'tests/inspect-camera-permissions.c'),
                        '-o', str(inspector), *flags], check=True)
        publisher = directory / 'publisher'
        flags = shlex.split(subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'libpipewire-0.3',
             'gstreamer-app-1.0', 'gstreamer-video-1.0'], text=True))
        subprocess.run(['cc', '-Wall', '-Wextra', '-O2',
                        str(ROOT / 'surface-camera-publisher.c'), '-o', str(publisher), *flags], check=True)
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
            for name, role in [(BACKEND, 'Camera')]:
                start(['gst-launch-1.0', '-q', 'videotestsrc', 'is-live=true', '!',
                       'video/x-raw,width=640,height=480,framerate=30/1', '!',
                       'pipewiresink', 'mode=provide',
                       f'stream-properties=props,node.name={name},media.class=Video/Source,media.role={role}'])
            publisher_log = directory / 'publisher.log'
            with publisher_log.open('w') as log:
                public_process = subprocess.Popen([str(publisher), 'front', '--test-source'],
                                                   env=env, stdout=log, stderr=log)
            processes.append(public_process)
            time.sleep(0.6)
            assert 'capture active' not in publisher_log.read_text(), 'Idle publisher started physical capture'
            nodes = monitor_graph(env)
            assert BACKEND not in nodes, 'Native backend is visible to apps'
            assert PUBLIC in nodes, 'Public webcam was accidentally hidden'
            inspect = subprocess.Popen([str(inspector), 'surface11-test-portal'], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                output, error = inspect.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                inspect.terminate()
                output, error = inspect.communicate(timeout=3)
            visible = {}
            for line in output.splitlines():
                if line.startswith('REMOVED '):
                    visible.pop(line.split()[1], None)
                else:
                    visible[line.split()[0]] = line
            graph = '\n'.join(visible.values())
            assert PUBLIC in graph, f'Portal client lost public camera: {error}'
            assert BACKEND not in graph, 'Portal client can still bypass the shared camera'
            for reopen in range(3):
                subprocess.run([
                    'timeout', '5s', 'gst-launch-1.0', '-q', 'pipewiresrc',
                    'client-properties=props,application.name=surface11-camera-relay',
                    'stream-properties=props,node.dont-fallback=true',
                    f'target-object={BACKEND}', 'num-buffers=3', '!',
                    'video/x-raw,format=RGBx,width=640,height=480', '!', 'fakesink',
                ], env=env, check=True)
            # Match a portal consumer and an ordinary consumer concurrently.
            # Both must receive actual frames through the real MemFd publisher.
            consumers = []
            for app in ['surface11-test-portal', 'surface11-test-ordinary']:
                consumers.append(subprocess.Popen([
                    'gst-launch-1.0', '-q', 'pipewiresrc',
                    f'client-properties=props,application.name={app}',
                    f'target-object={PUBLIC}', 'num-buffers=45', '!',
                    'video/x-raw,format=YUY2,width=640,height=480', '!',
                    'videoconvert', '!', 'video/x-raw,format=RGBx', '!', 'fakesink',
                ], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            try:
                for consumer in consumers:
                    _, error = consumer.communicate(timeout=10)
                    assert consumer.returncode == 0, error.decode()
            finally:
                for consumer in consumers:
                    if consumer.poll() is None:
                        consumer.kill(); consumer.wait()
            time.sleep(0.6)
            log = publisher_log.read_text()
            assert 'capture active' in log and 'capture idle' in log, log
            assert public_process.poll() is None, log
            # Reopen after idle; the source must be restartable.
            subprocess.run(['timeout', '8s', 'gst-launch-1.0', '-q', 'pipewiresrc',
                            f'target-object={PUBLIC}', 'num-buffers=15', '!',
                            'video/x-raw,format=YUY2,width=640,height=480', '!', 'fakesink'],
                           env=env, check=True)
            # Probe/disconnect bursts mimic PipeWire STREAM/PAUSE/STREAM churn
            # without an idle grace interval between clients.
            for restart in range(6):
                subprocess.run(['timeout', '5s', 'gst-launch-1.0', '-q', 'pipewiresrc',
                                f'target-object={PUBLIC}', 'num-buffers=1', '!',
                                'video/x-raw,format=YUY2,width=640,height=480', '!', 'fakesink'],
                               env=env, check=True)
                assert public_process.poll() is None, publisher_log.read_text()
            raw = subprocess.check_output(['timeout', '8s', 'gst-launch-1.0', '-q',
                'pipewiresrc', f'target-object={PUBLIC}', 'num-buffers=30', '!',
                'video/x-raw,format=YUY2,width=640,height=480', '!', 'fdsink', 'fd=1'], env=env)
            frame_size = 640 * 480 * 2
            assert len(raw) == frame_size * 30, 'Incomplete shared-memory frames'
            frames = [raw[i:i + frame_size] for i in range(0, len(raw), frame_size)]
            assert len({hashlib.sha256(f).digest() for f in frames[15:]}) >= 3, 'Publisher froze or emitted placeholders'
            print('PASS: shared-memory publisher delivers concurrent portal/ordinary streams, idles, survives rapid probes and reopens')
            print('PASS: ordinary and portal-managed apps see only public webcams; relay receives Camera-role native frames')
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
