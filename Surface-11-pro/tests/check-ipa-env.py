#!/usr/bin/env python3
"""Check package-version fallback and current-package portal override refresh."""
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
    portal = directory / 'client/find-portal-access.lua'
    command = ['bash', str(ROOT / 'surface-camera-ipa-env.sh'), str(ipa), str(env), str(portal)]
    subprocess.run(command, check=True)
    assert str(ipa) in env.read_text()
    assert 'return Perm.NONE' in portal.read_text()
    assert 'getCameraPermissions' in portal.read_text()  # stock permission checks retained
    assert 'Ungated portal client' in portal.read_text()  # stock gate handling retained
    (ipa / 'packages.txt').write_text('changed packages\n')
    subprocess.run(command, check=True)
    assert env.read_text() == 'LIBCAMERA_IPA_MODULE_PATH=\n'
    portal.write_text('-- Unmanaged custom policy\n')
    subprocess.run(command, check=True)
    assert portal.read_text() == '-- Unmanaged custom policy\n'
print('PASS: matching-package IPA, upgrade fallback, portal refresh and unmanaged-file preservation')
