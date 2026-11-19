"""Exercise the real update script with isolated files and fake system services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class QualityUpdateTests(unittest.TestCase):
    def run_update(self, fail_at=None, previous_override=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            tools = base / 'bin'
            tools.mkdir()
            libexec = base / 'installed'
            libexec.mkdir()
            (libexec / 'managed-by-surface11-camera').touch()
            binary = libexec / 'surface-camera-relay'
            binary.write_text('#!/bin/bash\nexit 0\n')
            binary.chmod(0o755)
            installed = libexec / 'surface-camera-relay.sh'
            installed.write_text('# original working wrapper\n')
            candidate = base / 'surface-camera-relay.sh'
            candidate.write_text('#!/bin/bash\nexit 0\n')
            override = base / 'config/systemd/user/surface11-cameras.service.d/80-surface11-quality.conf'
            original_override = '# Managed by surface11-camera quality\n[Service]\nEnvironment=SURFACE11_CAMERA_QUALITY=detail\n'
            if previous_override:
                override.parent.mkdir(parents=True)
                override.write_text(original_override)
            script = base / 'update.sh'
            script.write_text((ROOT / 'camera/set-camera-quality.sh').read_text().replace(
                'libexec=/usr/local/libexec/surface11-camera', f'libexec="{libexec}"'))
            mocks = {
                'sudo': '#!/bin/bash\necho unexpected-sudo >> "$TRACE"\nexit 99\n',
                'systemctl': '#!/bin/bash\necho "$*" >> "$TRACE"\nexit 0\n',
                'python3': '''#!/bin/bash
n=0
[[ ! -f $COUNT ]] || read -r n < "$COUNT"
echo "$((n+1))" > "$COUNT"
cat >/dev/null
[[ $n != "$FAIL_AT" ]]
''',
            }
            for name, body in mocks.items():
                path = tools / name
                path.write_text(body)
                path.chmod(0o755)
            env = {**os.environ, 'PATH': f'{tools}:{os.environ["PATH"]}',
                   'XDG_CONFIG_HOME': str(base / 'config'), 'XDG_STATE_HOME': str(base / 'state'),
                   'TRACE': str(base / 'trace'), 'COUNT': str(base / 'count'),
                   'FAIL_AT': str(fail_at)}
            result = subprocess.run(['bash', str(script), 'natural'], env=env,
                                    text=True, capture_output=True)
            self.assertNotIn('unexpected-sudo', (base / 'trace').read_text())
            if fail_at is None:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(installed.read_text(), '# original working wrapper\n')
                runtimes = list((base / 'state/surface11-camera/quality-backups').glob('*/runtime/surface-camera-relay.sh'))
                self.assertEqual(len(runtimes), 1)
                self.assertEqual(runtimes[0].read_text(), candidate.read_text())
                self.assertIn(str(runtimes[0]), override.read_text())
                self.assertIn('SURFACE11_CAMERA_QUALITY=natural', override.read_text())
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(installed.read_text(), '# original working wrapper\n')
                if previous_override:
                    self.assertEqual(override.read_text(), original_override)
                else:
                    self.assertFalse(override.exists())
                trace = (base / 'trace').read_text()
                if fail_at == 0:
                    self.assertNotIn('restart', trace)
                    self.assertNotIn('-v', trace)
                else:
                    self.assertEqual(trace.count('restart surface11-cameras.service'), 2)
                    self.assertEqual((base / 'count').read_text().strip(), '3')

    def test_success(self):
        self.run_update()

    def test_baseline_failure_changes_nothing(self):
        self.run_update(fail_at=0)

    def test_failed_capture_keeps_wrapper_and_removes_new_override(self):
        self.run_update(fail_at=1)

    def test_failed_capture_restores_existing_override(self):
        self.run_update(fail_at=1, previous_override=True)


if __name__ == '__main__':
    unittest.main()
