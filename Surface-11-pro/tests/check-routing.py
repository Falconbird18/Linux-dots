#!/usr/bin/env python3
"""Catch missing, duplicate, or accidentally exposed camera routes."""
import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path

path = Path(__file__).resolve().parent.parent / 'camera/check-camera-routing.py'
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
raw = node('v4l2_input.pci-0000_00_05.0', 0, 'ipu7 (V4L2)')
raw['info']['props'].update({'api.v4l2.cap.driver': 'isys', 'api.v4l2.cap.card': 'ipu7'})
assert module.routing_errors(pair + [raw])
usb = node('usb-webcam', 7, 'USB Camera')
usb['info']['props'].update({'api.v4l2.cap.driver': 'uvcvideo'})
assert not module.routing_errors(pair + [usb])
print('PASS: missing/duplicate public cameras and exposed native backends are rejected')
