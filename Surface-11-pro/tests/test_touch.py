import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
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
    def test_dock_autohides(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'BAR_AUTO_HIDE_SUCCESS')) as run:
            self.assertTrue(touch.set_dock_autohide())
            self.assertEqual(run.call_args.args[0][-1], 'autoHide')

    def test_unavailable_dock_is_retried(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'DOCK_NOT_FOUND')):
            self.assertFalse(touch.set_dock_autohide())
        with patch.object(touch.subprocess, 'run', side_effect=subprocess.TimeoutExpired('dms', 4)):
            self.assertFalse(touch.set_dock_autohide())


class CursorMode(unittest.TestCase):
    def test_uses_lua_and_validates_reply(self):
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok\n')) as run:
            self.assertTrue(touch.set_cursor_mode(True))
            self.assertEqual(run.call_args.args[0][1], 'eval')
            self.assertIn('invisible=true', run.call_args.args[0][2])
        with patch.object(touch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'unknown request')):
            self.assertFalse(touch.set_cursor_mode(False))


class KeyboardStartup(unittest.TestCase):
    def test_focus_controls_keyboard_and_cursor_tracks_mode(self):
        keyboard, effects = MagicMock(), MagicMock()
        keyboard.poll.return_value = effects.poll.return_value = None
        with patch.object(touch, 'needs_keyboard', side_effect=[True, True, False]), \
             patch.object(touch, 'set_dock_autohide', return_value=True), \
             patch.object(touch, 'set_cursor_mode', return_value=True) as cursor, \
             patch.object(touch.shutil, 'which', return_value='/usr/bin/squeekboard'), \
             patch.object(touch.subprocess, 'Popen', side_effect=[effects, keyboard]) as start, \
             patch.object(touch.subprocess, 'run') as settings, \
             patch.object(touch.time, 'sleep', side_effect=[None, None, KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):
                touch.main()
            self.assertEqual(start.call_args_list[1].args[0], ['squeekboard'])
            self.assertEqual(settings.call_args.args[0][-2:], ['screen-keyboard-enabled', 'true'])
            # Never force visibility; native text-input activation owns show/hide.
            self.assertFalse(any('SetVisible' in call.args[0] for call in settings.call_args_list))
            self.assertEqual([call.args[0] for call in cursor.call_args_list], [True, False, False])
        keyboard.terminate.assert_called_once()
        effects.terminate.assert_called_once()

    def test_desktop_never_starts_keyboard_or_feedback(self):
        with patch.object(touch, 'needs_keyboard', return_value=False), \
             patch.object(touch, 'set_dock_autohide', return_value=True), \
             patch.object(touch, 'set_cursor_mode', return_value=True), \
             patch.object(touch.shutil, 'which', return_value='/usr/bin/squeekboard'), \
             patch.object(touch.subprocess, 'Popen') as start, \
             patch.object(touch.time, 'sleep', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                touch.main()
            start.assert_not_called()


if __name__ == '__main__':
    unittest.main()
