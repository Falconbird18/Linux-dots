#!/usr/bin/env python3
"""Use the locally built, pinned relay source to check its real input lifecycle."""
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
cached = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'surface11-camera/relay.c'
if not cached.is_file():
    print('SKIP: relay lifecycle compile test requires the pinned relay source from a camera build')
    raise SystemExit(0)
spec = importlib.util.spec_from_file_location('lifecycle', ROOT / 'patch-relay-lifecycle.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
with tempfile.TemporaryDirectory(prefix='surface11-lifecycle-') as directory:
    directory = Path(directory)
    source = cached.read_text()
    if 'static gboolean backend_failed = FALSE;' not in source:
        source = patcher.patch(source)
    path = directory / 'relay.c'; path.write_text(source)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
        'gstreamer-1.0', 'gstreamer-app-1.0', 'gstreamer-video-1.0', 'gio-unix-2.0'], text=True))
    executable = directory / 'lifecycle'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Wno-unused-parameter', '-O2',
        f'-I{ROOT}', f'-DRELAY_SOURCE="{path}"', '-DV4L2_RELAYD_VERSION="lifecycle-test"',
        str(ROOT / 'tests/test-relay-lifecycle.c'), '-o', str(executable), *flags], check=True)
    subprocess.run([str(executable)], check=True)
spec = importlib.util.spec_from_file_location('shared_check', ROOT / 'check-shared-camera.py')
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
