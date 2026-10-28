"""Run with python3 -m unittest discover -s Surface-11-pro/tests -p 'test_autorotate.py'."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('autorotate', Path(__file__).resolve().parents[1] / 'input/surface11-autorotate.py')
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class RotationTests(unittest.TestCase):
    def test_no_rotation_without_reading(self):
        self.assertFalse(rotation.Debounce().ready(100))

    def test_jitter_restarts_settling(self):
        d = rotation.Debounce()
        d.feed(1, 0)
        d.feed(0, .3)
        d.feed(1, .5)
        self.assertFalse(d.ready(.8))
        self.assertFalse(d.ready(2.4))
        self.assertTrue(d.ready(2.6))

    def test_duplicate_readings_do_not_delay_rotation(self):
        d = rotation.Debounce()
        d.feed(1, 0)
        d.feed(1, .4)
        self.assertFalse(d.ready(.5))
        self.assertTrue(d.ready(2.1))

    def test_cooldown(self):
        d = rotation.Debounce()
        d.last = 1
        d.feed(2, 1.1)
        self.assertFalse(d.ready(1.8))
        self.assertFalse(d.ready(4.9))
        self.assertTrue(d.ready(5.1))

    def test_brief_bed_movements_never_rotate(self):
        d = rotation.Debounce()
        # Each accidental threshold crossing lasts longer than the old 450 ms.
        for now, value in ((0, 0), (3, 1), (4.2, 0), (6, 1), (7.5, 0)):
            d.feed(value, now)
            if value == 1:
                self.assertFalse(d.ready(now + 1.0))
        self.assertTrue(d.ready(9.6))
        self.assertEqual(d.pending, 0)

    def test_deliberate_rotation_after_hold_and_cooldown(self):
        d = rotation.Debounce()
        d.last = 0
        d.feed(1, 1)
        self.assertFalse(d.ready(3.5))
        self.assertTrue(d.ready(4.1))
        d.last = 4.1
        d.feed(0, 4.2)
        self.assertFalse(d.ready(6.3))
        self.assertTrue(d.ready(8.2))

    def test_initial_and_changed_sensor_messages(self):
        for value in rotation.TRANSFORMS:
            for message in (f'=== Has accelerometer (orientation: {value})',
                            f'    Accelerometer orientation changed: {value}'):
                self.assertEqual(rotation.ORIENTATION.search(message)[1], value)
        self.assertIsNone(rotation.ORIENTATION.search('Accelerometer orientation changed: undefined'))

    @patch.object(rotation, 'hypr', return_value='ok\n')
    def test_only_transform_changes_and_inputs_follow(self, ipc):
        rotation.apply_rotation('eDP-1', 3)
        command, lua = ipc.call_args.args
        self.assertEqual(command, 'eval')
        self.assertIn('hl.monitor({output="eDP-1", transform=3})', lua)
        self.assertIn('touchdevice={output="eDP-1", transform=3}', lua)
        self.assertIn('tablet={output="eDP-1", transform=3}', lua)
        for setting in ('mode=', 'scale=', 'position=', 'vrr=', 'bitdepth='):
            self.assertNotIn(setting, lua)

    @patch.object(rotation, 'hypr', return_value='error: invalid configuration')
    def test_ipc_failure_is_not_recorded_as_success(self, _):
        with self.assertRaises(RuntimeError):
            rotation.apply_rotation('eDP-1', 1)


if __name__ == '__main__':
    unittest.main()
