#!/usr/bin/env python3
"""Catch missing, duplicate, or accidentally exposed camera routes."""
import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path

path = Path(__file__).resolve().parent.parent / 'check-camera-routing.py'
spec = importlib.util.spec_from_file_location('camera_routing', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def node(name, number, label):
    return {'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'node.name': name, 'api.v4l2.path': f'/dev/video{number}',
        'node.description': label, 'media.class': 'Video/Source', 'media.role': 'Camera',
    }}}


pair = [node('surface11-camera-front', 42, 'Surface Front Camera'),
        node('surface11-camera-rear', 43, 'Surface Rear Camera')]
assert not module.routing_errors(pair)
assert module.routing_errors(pair[:1])
assert module.routing_errors(pair + [node('monitor-copy', 42, 'Duplicate')])
assert module.routing_errors(pair + [node(next(iter(module.BACKENDS)), 0, 'Native')])
print('PASS: missing/duplicate public cameras and exposed native backends are rejected')
