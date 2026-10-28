import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location('touch', Path(__file__).parents[1] / 'input/surface11-touch.py')
touch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(touch)


class KeyboardDetection(unittest.TestCase):
    def device(self, root, number, keys, name='USB keyboard'):
        device = root / f'event{number}/device'
        (device / 'capabilities').mkdir(parents=True)
        bits = sum(1 << key for key in keys)
        words = []
        while bits:
            words.append(f'{bits & ((1 << 64) - 1):x}')
            bits >>= 64
        (device / 'capabilities/key').write_text(' '.join(reversed(words)) or '0')
        (device / 'name').write_text(name)
        return device

    def test_detached_and_hotkey_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertTrue(touch.needs_keyboard(root))
            self.device(root, 0, [114, 115, 116], 'gpio-keys')
            self.assertTrue(touch.needs_keyboard(root))

    def test_real_typing_keyboard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.device(root, 0, [16, 28, 30, 44, 57, 116])
            self.assertFalse(touch.needs_keyboard(root))

    def test_folded_cover_and_external_keyboard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.device(root, 0, [16, 28, 30, 44, 57], 'Microsoft Surface Keyboard')
            with patch.object(touch, 'tablet_switch', return_value=True):
                self.assertTrue(touch.needs_keyboard(root))
                self.device(root, 1, [16, 28, 30, 44, 57], 'USB keyboard')
                self.assertFalse(touch.needs_keyboard(root))

    def test_virtual_keyd_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.device(root / 'virtual', 0, [16, 28, 30, 44, 57])
            (root / 'event0').symlink_to(root / 'virtual/event0')
            self.assertTrue(touch.needs_keyboard(root))


class DockMode(unittest.TestCase):
    def test_tablet_keeps_dock_visible(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'BAR_MANUAL_HIDE_SUCCESS')) as run:
            self.assertTrue(touch.set_dock_tablet_mode(True))
            self.assertEqual(run.call_args.args[0][-1], 'manualHide')

    def test_desktop_autohides_dock(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'BAR_AUTO_HIDE_SUCCESS')) as run:
            self.assertTrue(touch.set_dock_tablet_mode(False))
            self.assertEqual(run.call_args.args[0][-1], 'autoHide')

    def test_unavailable_dock_is_retried(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'DOCK_NOT_FOUND')):
            self.assertFalse(touch.set_dock_tablet_mode(True))
        with patch.object(touch.subprocess, 'run', side_effect=subprocess.TimeoutExpired('dms', 4)):
            self.assertFalse(touch.set_dock_tablet_mode(True))


if __name__ == '__main__':
    unittest.main()
