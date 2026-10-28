#!/usr/bin/env python3
"""Check the maintained relay lifecycle and shared-camera image validation."""
import importlib.util
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='surface11-lifecycle-') as directory:
    executable = Path(directory) / 'lifecycle'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
        'gstreamer-1.0', 'gstreamer-app-1.0', 'gstreamer-video-1.0', 'gio-unix-2.0'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-Wno-unused-parameter', '-O2',
        str(ROOT / 'tests/test-relay-lifecycle.c'), '-o', str(executable), *flags], check=True)
    subprocess.run([str(executable)], check=True)
spec = importlib.util.spec_from_file_location('shared_check', ROOT / 'camera/check-shared-camera.py')
shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
for result in [{'distinct': 1, 'p95': 150, 'p05': 50}, {'distinct': 30, 'p95': 17, 'p05': 16}]:
    try:
        shared.check(result)
    except ValueError:
        pass
    else:
        raise AssertionError('Frozen/placeholder output must fail shared check')
shared.check({'distinct': 90, 'p95': 180, 'p05': 30})
print('PASS: shared-image validation rejects frozen and uniform output')
