"""Exercise the real rotation installer with privileged commands recorded, not run."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['INSTALL_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'cat':
    dmi = {'sys_vendor': 'Microsoft Corporation',
           'product_name': os.environ.get('INSTALL_TEST_MODEL', 'Surface Pro for Business 11th Edition with Intel'),
           'product_sku': 'Surface_Pro_11th_Edition_With_Intel_For_Business_2103'}
    if len(args) == 1 and args[0].startswith('/sys/class/dmi/id/'):
        print(dmi[Path(args[0]).name])
    else:
        os.execv('/usr/bin/cat', ['cat', *args])
if name == 'uname':
    print('x86_64' if args == ['-m'] else 'test-kernel')
if name == 'sudo' and os.environ.get('INSTALL_TEST_FAIL_SUDO'):
    sys.exit(1)
'''


@unittest.skipIf(os.geteuid() == 0, 'Installer must run as the desktop user')
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        for name in ('sudo', 'systemctl', 'pacman', 'hyprctl', 'cat', 'uname'):
            executable = self.bin / name
            executable.write_text(STUB)
            executable.chmod(0o755)
        self.config = self.home / '.config/hypr/hyprland.lua'
        self.config.parent.mkdir(parents=True)
        self.config.write_text('-- original configuration\n')
        self.log = self.home / 'calls.jsonl'
        self.env = {**os.environ, 'HOME': str(self.home),
                    'XDG_CONFIG_HOME': str(self.home / '.config'),
                    'XDG_RUNTIME_DIR': str(self.home),
                    'HYPRLAND_INSTANCE_SIGNATURE': 'test-instance',
                    'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'INSTALL_TEST_LOG': str(self.log)}

    def run_installer(self, top_level=True, mode='rotation', **env):
        script = ROOT / ('install-surface11.sh' if top_level else 'input/setup-autorotation.sh')
        return subprocess.run(['bash', str(script), mode], env={**self.env, **env},
                              capture_output=True, text=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_main_rotation_command_repairs_sensor_before_starting_daemon(self):
        for _ in range(2):
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        rule = ['sudo', 'install', '-Dm644', str(ROOT / 'input/81-surface11-accelerometer.rules'),
                '/etc/udev/rules.d/81-surface11-accelerometer.rules']
        reload_rules = ['sudo', 'udevadm', 'control', '--reload-rules']
        trigger = ['sudo', 'udevadm', 'trigger', '--settle', '--action=change',
                   '--subsystem-match=iio', '--attr-match=name=accel_3d']
        proxy = ['sudo', 'systemctl', 'restart', 'iio-sensor-proxy.service']
        daemon = ['systemctl', '--user', 'restart', 'surface11-autorotate.service']
        self.assertEqual(calls.count(rule), 2)
        for before, after in zip((rule, reload_rules, trigger, proxy),
                                 (reload_rules, trigger, proxy, daemon)):
            self.assertLess(calls.index(before), calls.index(after))
        self.assertEqual(self.config.read_text().count('-- SURFACE11_AUTOROTATE_BEGIN'), 1)
        self.assertEqual(self.config.with_name('hyprland.lua.before-surface11-rotation').read_text(),
                         '-- original configuration\n')
        self.assertEqual((self.home / '.local/lib/surface11/autorotate.py').read_bytes(),
                         (ROOT / 'input/surface11-autorotate.py').read_bytes())

    def test_failed_privileged_install_does_not_start_rotation(self):
        result = self.run_installer(INSTALL_TEST_FAIL_SUDO='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / '.config/systemd/user/surface11-autorotate.service').exists())
        self.assertNotIn(['systemctl', '--user', 'restart', 'surface11-autorotate.service'], self.calls())

    def test_other_model_does_not_trigger_or_restart_sensor(self):
        result = self.run_installer(top_level=False, mode='install', INSTALL_TEST_MODEL='Other model')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:3] == ['sudo', 'udevadm', 'trigger'] for call in self.calls()))
        self.assertNotIn(['sudo', 'systemctl', 'restart', 'iio-sensor-proxy.service'], self.calls())

    def test_status_does_not_install_or_restart_anything(self):
        result = self.run_installer(top_level=False, mode='status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [['systemctl', '--user', '--no-pager', 'status',
                                         'surface11-autorotate.service']])


@unittest.skipUnless(shutil.which('udevadm'), 'udevadm is not installed')
class RuleTests(unittest.TestCase):
    def test_rule_syntax(self):
        result = subprocess.run(['udevadm', 'verify', str(ROOT / 'input/81-surface11-accelerometer.rules')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
