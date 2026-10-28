import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import os
from unittest.mock import MagicMock

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


class KeyboardStartup(unittest.TestCase):
    def exercise(self, modes, manual=False):
        with tempfile.TemporaryDirectory() as tmp:
            request = Path(tmp) / 'surface11-keyboard-show'
            if manual:
                request.touch()
            child = MagicMock()
            child.poll.return_value = None
            with patch.dict(os.environ, XDG_RUNTIME_DIR=tmp), \
                 patch.object(touch, 'needs_keyboard', side_effect=modes), \
                 patch.object(touch, 'set_dock_tablet_mode', return_value=True), \
                 patch.object(touch.shutil, 'which', return_value='/usr/bin/squeekboard'), \
                 patch.object(touch.subprocess, 'Popen', return_value=child) as start, \
                 patch.object(touch.subprocess, 'run') as settings, \
                 patch.object(touch, 'show_keyboard', side_effect=[False, True]) as show, \
                 patch.object(touch.time, 'sleep', side_effect=[None] * (len(modes)-1) + [KeyboardInterrupt]):
                with self.assertRaises(KeyboardInterrupt):
                    touch.main()
                start.assert_called_once_with(['squeekboard'])
                self.assertEqual(settings.call_args.args[0][-2:], ['screen-keyboard-enabled', 'true'])
                self.assertEqual(show.call_count, 2)
                self.assertFalse(request.exists())
            child.terminate.assert_called_once()

    def test_tablet_enables_keyboard_retries_show_then_stops_on_attach(self):
        self.exercise([True, True, False])

    def test_manual_show_works_in_tablet_mode(self):
        self.exercise([True, True], manual=True)

    def test_manual_launcher_rejects_hardware_keyboard(self):
        with patch.object(touch, 'needs_keyboard', return_value=False), \
             patch.object(touch.subprocess, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'only available in tablet mode'):
                touch.request_keyboard()
            run.assert_not_called()

    def test_stale_manual_request_cannot_bypass_tablet_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            request = Path(tmp) / 'surface11-keyboard-show'
            request.touch()
            with patch.dict(os.environ, XDG_RUNTIME_DIR=tmp), \
                 patch.object(touch, 'needs_keyboard', return_value=False), \
                 patch.object(touch, 'set_dock_tablet_mode', return_value=True), \
                 patch.object(touch.shutil, 'which', return_value='/usr/bin/squeekboard'), \
                 patch.object(touch.subprocess, 'Popen') as start, \
                 patch.object(touch, 'show_keyboard') as show, \
                 patch.object(touch.time, 'sleep', side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    touch.main()
                start.assert_not_called()
                show.assert_not_called()
                self.assertFalse(request.exists())


if __name__ == '__main__':
    unittest.main()
