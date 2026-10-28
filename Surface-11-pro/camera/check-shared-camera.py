#!/usr/bin/env python3
"""Verify live images after reopening each public PipeWire camera."""
import importlib.util
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import time

spec = importlib.util.spec_from_file_location('quality', Path(__file__).with_name('check-camera-quality.py'))
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def check(result):
    if result['distinct'] < 3:
        raise ValueError('Frozen/repeated frames; move an object in view and retry')
    if result['p95'] - result['p05'] <= 2:
        raise ValueError('Uniform/black frames; aim at a lit, varied scene and retry')


def check_pair():
    with ThreadPoolExecutor(max_workers=2) as pool:
        jobs = {camera: pool.submit(
            quality.capture,
            f'pipewiresrc target-object=surface11-camera-{camera} stream-properties=props,node.dont-fallback=true',
            count=90, warmup=8) for camera in ['front', 'rear']}
        for camera, job in jobs.items():
            check(job.result())
            print(f'PASS: {camera}: simultaneous front/rear capture')


if __name__ == '__main__':
    for camera, number in [('front', 42), ('rear', 43)]:
        for attempt in range(2):
            routes = {
                'PipeWire': f'pipewiresrc target-object=surface11-camera-{camera} stream-properties=props,node.dont-fallback=true',
                'V4L2 mmap': f'v4l2src device=/dev/video{number} io-mode=mmap',
                'V4L2 read': f'v4l2src device=/dev/video{number} io-mode=rw',
            }
            # v4l2loopback 0.15 has one capture owner, like many physical V4L2
            # drivers. Share clients through PipeWire; test direct APIs alone.
            for name, source in routes.items():
                if name == 'PipeWire':
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        jobs = [pool.submit(quality.capture, source, count=90, warmup=8)
                                for _ in range(2)]
                        for job in jobs:
                            check(job.result())
                else:
                    check(quality.capture(source, count=90, warmup=8))
                print(f'PASS: {camera} open {attempt + 1}, {name}: changing, nonuniform images')
                time.sleep(1)
            time.sleep(1)
    check_pair()
