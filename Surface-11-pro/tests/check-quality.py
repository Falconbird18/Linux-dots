#!/usr/bin/env python3
"""Execute the exact processing chains using synthetic frames, no cameras."""
import importlib.util
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst
Gst.init(None)
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('camera_quality', ROOT / 'check-camera-quality.py')
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def process(profile, camera, pixels, fmt='I420', color='bt709', orientation=True):
    descriptions = subprocess.check_output(
        ['bash', str(ROOT / 'surface-camera-relay.sh'), camera, '--describe'],
        env={**os.environ, 'SURFACE11_CAMERA_QUALITY': profile}, text=True).splitlines()
    processing = descriptions[0].split(' ! ', 1)[1]
    if not orientation:
        processing = processing.replace('method=rotate-180', 'method=none')
    pipeline = Gst.parse_launch(
        f'appsrc name=test format=time caps="video/x-raw,format={fmt},width=1280,'
        f'height=720,framerate=30/1,colorimetry={color}" ! videoscale ! '
        f'{processing} ! '
        'appsink name=result sync=false')
    try:
        pipeline.set_state(Gst.State.PLAYING)
        source = pipeline.get_by_name('test')
        for n in range(2):
            buffer = Gst.Buffer.new_wrapped(pixels)
            buffer.pts = n * Gst.SECOND // 30
            buffer.duration = Gst.SECOND // 30
            assert source.emit('push-buffer', buffer) == Gst.FlowReturn.OK
        source.emit('end-of-stream')
        sample = pipeline.get_by_name('result').emit('try-pull-sample', 5 * Gst.SECOND)
        if sample is None:
            message = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR)
            raise AssertionError(message.parse_error() if message else 'Synthetic chain timed out')
        assert sample.get_caps().get_structure(0).get_string('colorimetry') == 'bt709'
        buffer = sample.get_buffer()
        output = buffer.extract_dup(0, buffer.get_size())
        assert len(output) == 1280 * 720 * 2
        return output
    finally:
        pipeline.set_state(Gst.State.NULL)


rng = random.Random(41)
y = bytes(110 + rng.choice([-30, 30]) if rng.random() < 0.1 else 110
          for _ in range(1280 * 720))
raw = y + bytes([128]) * (1280 * 720 // 2)
detail = process('detail', 'front', raw)[::2]
balanced = process('balanced', 'front', raw)[::2]
# A spatial filter must materially reduce seeded noise, without changing exposure.
assert statistics.pvariance(balanced) < statistics.pvariance(detail) * 0.35
assert abs(statistics.fmean(balanced) - statistics.fmean(detail)) < 1
# An asymmetric scene must rotate in the pixels, not just in camera metadata.
scene = bytes(50 if col < 400 and row < 250 else 180
              for row in range(720) for col in range(1280))
scene += bytes([128]) * (1280 * 720 // 2)
front = process('detail', 'rear', scene, orientation=False)[::2]
rear = process('detail', 'rear', scene)[::2]
assert rear == front[::-1], 'Rear pixels must be rotated by 180 degrees'
# Check RGB -> video range conversion, including the exact rear rotation chain.
for profile in ['balanced', 'detail']:
    for camera in ['front', 'rear']:
        black = process(profile, camera, bytes(1280 * 720 * 3), 'RGB', 'sRGB')[::2]
        white = process(profile, camera, bytes([255]) * (1280 * 720 * 3), 'RGB', 'sRGB')[::2]
        assert max(abs(v - 16) for v in black) <= 1
        assert max(abs(v - 235) for v in white) <= 1
# The diagnostic must distinguish startup convergence from settled variation.
frames = [bytes([40]) * 20] * 90 + [bytes([110]) * 20] * 90
result = quality.summarize(frames)
assert result['start_mean'] == 40 and result['end_mean'] == 110
assert result['mean_span'] == 0 and result['temporal_rms'] == 0
assert result['black_pct'] == 0 and result['white_pct'] == 0
clipped = quality.summarize([bytes([16, 235]) * 10] * 180)
assert clipped['black_pct'] == 50 and clipped['white_pct'] == 50
synthetic = quality.capture('videotestsrc is-live=false pattern=black')
assert synthetic['p50'] == 16 and synthetic['distinct'] == 1
print('PASS: exact chains reduce synthetic noise, preserve mean, map RGB black/white to video range; exposure metrics distinguish startup from settled frames')
