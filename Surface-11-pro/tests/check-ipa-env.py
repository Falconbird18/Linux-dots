#!/usr/bin/env python3
"""Check package-version matching and upgrade fallback."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='surface11-ipa-') as temporary:
    directory = Path(temporary)
    ipa = directory / 'ipa'; ipa.mkdir()
    (ipa / 'ipa_soft_simple.so').write_bytes(b'test fixture')
    packages = subprocess.check_output(['pacman', '-Q', 'libcamera', 'libcamera-ipa'])
    (ipa / 'packages.txt').write_bytes(packages)
    env = directory / 'ipa-env'
    command = ['bash', str(ROOT / 'camera/surface-camera-ipa-env.sh'), str(ipa), str(env)]
    subprocess.run(command, check=True)
    assert str(ipa) in env.read_text()
    (ipa / 'packages.txt').write_text('changed packages\n')
    subprocess.run(command, check=True)
    assert env.read_text() == 'LIBCAMERA_IPA_MODULE_PATH=\n'
print('PASS: matching-package IPA and safe fallback after package changes')
