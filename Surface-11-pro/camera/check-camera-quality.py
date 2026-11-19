#!/usr/bin/env python3
"""Bounded in-memory image diagnostics. Metrics are not color calibration."""
import hashlib
import json
import math
import statistics
import time


def summarize(frames):
    if not frames:
        raise ValueError('No frames received')
    settled = frames[len(frames) // 2:]
    means = [statistics.fmean(f) for f in settled]
    values = sorted(v for f in settled for v in f)
    percentile = lambda p: values[min(len(values) - 1, int(len(values) * p))]
    differences = [a - b for first, second in zip(settled, settled[1:])
                   for a, b in zip(first, second)]
    return {
        'frames': len(frames),
        'distinct': len({hashlib.sha256(f).digest() for f in settled}),
        'start_mean': statistics.fmean(frames[0]),
        'end_mean': statistics.fmean(frames[-1]),
        'mean_span': max(means) - min(means),
        'temporal_rms': math.sqrt(statistics.fmean(x * x for x in differences)) if differences else 0,
        'p05': percentile(.05), 'p50': percentile(.5), 'p95': percentile(.95),
        'black_pct': 100 * sum(v <= 16 for v in values) / len(values),
        'white_pct': 100 * sum(v >= 235 for v in values) / len(values),
    }


def capture(source, count=180, deadline=35, warmup=0):
    import gi
    gi.require_version('Gst', '1.0')
    gi.require_version('GstVideo', '1.0')
    from gi.repository import Gst, GstVideo
    Gst.init(None)
    pipeline = Gst.parse_launch(
        source + ' ! videoconvert ! video/x-raw,format=YUY2,width=1280,height=720,'
        'colorimetry=bt709 ! appsink name=measure sync=false max-buffers=2 drop=true enable-last-sample=false')
    frames = []
    try:
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            message = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR)
            error = str(message.parse_error()) if message else 'Capture could not start'
            raise RuntimeError(error)
        start = time.monotonic()
        end = start + deadline
        sink = pipeline.get_by_name('measure')
        while len(frames) < count and time.monotonic() < end:
            sample = sink.emit('try-pull-sample', Gst.SECOND)
            if sample is None:
                message = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
                if message:
                    raise RuntimeError(str(message.parse_error()) if message.type == Gst.MessageType.ERROR else 'Unexpected end of stream')
                continue
            info = GstVideo.VideoInfo.new_from_caps(sample.get_caps())
            if time.monotonic() - start < warmup:
                sample = None
                continue
            buffer = sample.get_buffer()
            raw = buffer.extract_dup(0, buffer.get_size())
            # Sample a spatial grid, respecting row stride and plane offset.
            frames.append(bytes(raw[info.offset[0] + row * info.stride[0] + col * 2]
                                for row in range(0, 720, 8) for col in range(0, 1280, 8)))
            buffer = None
            sample = None
        if len(frames) != count:
            raise RuntimeError(f'Capture timed out after {len(frames)}/{count} frames')
        return summarize(frames)
    finally:
        pipeline.set_state(Gst.State.NULL)


if __name__ == '__main__':
    for camera in ['front', 'rear']:
        result = capture(f'pipewiresrc target-object=surface11-camera-{camera} stream-properties=props,node.dont-fallback=true', warmup=8)
        print(camera + ': ' + json.dumps(result, sort_keys=True))
    print('Clipping and temporal variation depend on the scene. These metrics do not certify color, lens distortion, or noise; inspect reference images in controlled light.')
