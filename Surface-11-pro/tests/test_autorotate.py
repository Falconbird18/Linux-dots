"""Run with python3 -m unittest discover -s Surface-11-pro/tests -p 'test_autorotate.py'."""
import importlib.util
import math
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('autorotate', Path(__file__).resolve().parents[1] / 'input/surface11-autorotate.py')
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class AngleTests(unittest.TestCase):
    @staticmethod
    def vector(degrees):
        radians = math.radians(degrees)
        return (9.80665 * math.sin(radians), -9.80665 * math.cos(radians), 0)

    def test_startup_latches_without_rotating(self):
        gate = rotation.AngleGate()
        self.assertFalse(gate.allows(self.vector(40)))
        self.assertFalse(gate.allows(self.vector(64.9)))
        self.assertTrue(gate.allows(self.vector(65)))

    def test_threshold_both_directions_and_no_reference_drift(self):
        gate = rotation.AngleGate()
        gate.reset(self.vector(0))
        for angle in (1, 10, 20, 24.99, -24.99, 0):
            self.assertFalse(gate.allows(self.vector(angle)))
        for angle in (25, -25, 90, 180):
            self.assertTrue(gate.allows(self.vector(angle)))

    def test_rotation_resets_reference(self):
        gate = rotation.AngleGate()
        gate.reset(self.vector(70))
        self.assertFalse(gate.allows(self.vector(80)))
        self.assertFalse(gate.allows(self.vector(50)))
        self.assertTrue(gate.allows(self.vector(45)))

    def test_dropping_below_threshold_cancels_hold(self):
        gate, debounce = rotation.AngleGate(), rotation.Debounce()
        gate.reset(self.vector(0))
        for now, angle in ((0, 30), (1.9, 20), (2, 30)):
            debounce.feed(1 if gate.allows(self.vector(angle)) else None, now)
        self.assertFalse(debounce.ready(3.9))
        self.assertTrue(debounce.ready(4.1))

    def test_axis_mounting_does_not_change_angle(self):
        a, b = self.vector(0), self.vector(24)
        for transform in (lambda v: v, lambda v: (-v[2], v[0], -v[1])):
            gate = rotation.AngleGate()
            gate.reset(transform(a))
            self.assertFalse(gate.allows(transform(b)))
            self.assertTrue(gate.allows(transform(self.vector(26))))

    def test_scaled_raw_values_and_invalid_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = Path(tmp) / 'iio:device7'
            device.mkdir()
            for axis, raw in zip('xyz', (0, -1000, 0)):
                (device / f'in_accel_{axis}_raw').write_text(str(raw))
            (device / 'in_accel_scale').write_text('0.00980665')
            (device / 'in_accel_offset').write_text('0')
            sensor = rotation.Accelerometer(Path(tmp))
            self.assertAlmostEqual(sensor.read()[1], -9.80665)
            (device / 'in_accel_y_raw').write_text('0')
            with self.assertRaises(RuntimeError):
                sensor.read()
            (device / 'in_accel_y_raw').write_text('nan')
            with self.assertRaises(RuntimeError):
                sensor.read()

    def test_missing_sensor_does_not_fall_back_to_labels(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                rotation.Accelerometer(Path(tmp))


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
