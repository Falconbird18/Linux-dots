"""Run with python3 -m unittest discover -s Surface-11-pro/tests -p 'test_autorotate.py'."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('autorotate', Path(__file__).resolve().parents[1] / 'input/surface11-autorotate.py')
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class SensorTests(unittest.TestCase):
    def test_initial_and_changed_sensor_messages(self):
        state = rotation.SensorState()
        for label, transform in rotation.TRANSFORMS.items():
            state.feed(f'=== Has accelerometer (orientation: {label}, tilt: vertical)')
            self.assertEqual(state.transform(), transform)
            state.feed(f'Accelerometer orientation changed: {label}')
            self.assertEqual(state.transform(), transform)
        state.feed('Accelerometer orientation changed: undefined')
        self.assertIsNone(state.transform())

    def test_flat_device_holds_until_raised(self):
        state = rotation.SensorState()
        state.feed('=== Has accelerometer (orientation: normal, tilt: face-up)')
        state.feed('Accelerometer orientation changed: left-up')
        self.assertIsNone(state.transform())
        state.feed('Tilt changed: tilted-up')
        self.assertEqual(state.transform(), 1)
        state.feed('Tilt changed: vertical')
        self.assertEqual(state.transform(), 1)
        state.feed('Tilt changed: face-down')
        self.assertIsNone(state.transform())

    def test_disconnect_clears_cached_orientation_and_tilt(self):
        for line in ('--- Accelerometer disappeared', '=== No accelerometer',
                     '--- iio-sensor-proxy vanished, waiting for it to appear'):
            with self.subTest(line=line):
                state = rotation.SensorState()
                state.feed('=== Has accelerometer (orientation: right-up, tilt: vertical)')
                state.feed(line)
                self.assertIsNone(state.transform())
                state.feed('=== Has accelerometer (orientation: left-up)')
                self.assertIsNone(state.transform())
                state.feed('Tilt changed: vertical')
                self.assertEqual(state.transform(), 1)

    def test_flat_or_unknown_tilt_blocks_rotation(self):
        for tilt in (None, 'undefined', 'face-up', 'face-down', 'unknown'):
            with self.subTest(tilt=tilt):
                state = rotation.SensorState()
                suffix = f', tilt: {tilt}' if tilt else ''
                state.feed(f'=== Has accelerometer (orientation: left-up{suffix})')
                self.assertIsNone(state.transform())

    def test_normal_viewing_angles_allow_all_orientations(self):
        for tilt in ('vertical', 'tilted-up', 'tilted-down'):
            for label, transform in rotation.TRANSFORMS.items():
                with self.subTest(tilt=tilt, label=label):
                    state = rotation.SensorState()
                    state.feed(f'=== Has accelerometer (orientation: {label}, tilt: {tilt})')
                    self.assertEqual(state.transform(), transform)


class RotationTests(unittest.TestCase):
    def test_no_rotation_without_reading(self):
        self.assertFalse(rotation.Debounce().ready(100))

    def test_jitter_and_sensor_loss_restart_settling(self):
        debounce = rotation.Debounce()
        for now, value in ((0, 1), (0.3, 0), (0.5, 1), (1, None), (1.5, 1)):
            debounce.feed(value, now)
        self.assertFalse(debounce.ready(2.4))
        self.assertTrue(debounce.ready(2.5))

    def test_duplicate_readings_do_not_delay_rotation(self):
        debounce = rotation.Debounce()
        debounce.feed(1, 0)
        debounce.feed(1, 0.4)
        self.assertFalse(debounce.ready(0.5))
        self.assertTrue(debounce.ready(1))

    def test_brief_movements_never_rotate(self):
        debounce = rotation.Debounce()
        for now, value in ((0, 0), (3, 1), (3.6, 0), (6, 1), (6.8, 0)):
            debounce.feed(value, now)
            if value == 1:
                self.assertFalse(debounce.ready(now + 0.5))
        self.assertTrue(debounce.ready(7.8))
        self.assertEqual(debounce.pending, 0)

    def test_subsecond_threshold_crossing_is_ignored(self):
        debounce = rotation.Debounce()
        debounce.feed(1, 0)
        self.assertFalse(debounce.ready(0.9))
        debounce.feed(0, 0.9)
        self.assertEqual(debounce.pending, 0)

    def test_successful_rotation_prevents_immediate_reversal(self):
        debounce = rotation.Debounce()
        debounce.feed(1, 0)
        self.assertTrue(debounce.ready(1))
        debounce.applied(1)
        debounce.feed(0, 1.1)
        self.assertFalse(debounce.ready(2.1))
        self.assertFalse(debounce.ready(2.9))
        self.assertTrue(debounce.ready(3))

    def test_flat_tilt_cancels_a_pending_rotation(self):
        state = rotation.SensorState()
        debounce = rotation.Debounce()
        for now, line in (
            (0, '=== Has accelerometer (orientation: left-up, tilt: vertical)'),
            (0.9, 'Tilt changed: face-up'),
            (10, 'Tilt changed: vertical'),
        ):
            state.feed(line)
            debounce.feed(state.transform(), now)
            self.assertFalse(debounce.ready(now))
        self.assertFalse(debounce.ready(10.9))
        self.assertTrue(debounce.ready(11))

    @patch.object(rotation, 'hypr', return_value='ok\n')
    def test_only_transform_changes_and_inputs_follow(self, ipc):
        rotation.apply_rotation('eDP-1', 3, True)
        command, lua = ipc.call_args.args
        self.assertEqual(command, 'eval')
        self.assertIn('hl.monitor({output="eDP-1", transform=3})', lua)
        self.assertIn('touchdevice={output="eDP-1", transform=3}', lua)
        self.assertIn('tablet={output="eDP-1", transform=3}', lua)

    @patch.object(rotation, 'hypr')
    def test_startup_syncs_inputs_even_when_display_already_matches(self, ipc):
        ipc.side_effect = ['[{"name":"eDP-1","transform":3}]', 'ok',
                           '[{"name":"eDP-1","transform":3}]']
        applied = rotation.reconcile_rotation(3, None)
        self.assertEqual(applied, ('eDP-1', 3))
        lua = ipc.call_args.args[1]
        self.assertNotIn('hl.monitor', lua)
        self.assertIn('touchdevice={output="eDP-1", transform=3}', lua)
        rotation.reconcile_rotation(3, applied)
        self.assertEqual(ipc.call_count, 3)

    @patch.object(rotation, 'hypr', return_value='[{"name":"HDMI-A-1","transform":0},'
                                                   '{"name":"eDP-1","dpmsStatus":false}]')
    def test_ignores_external_and_sleeping_panels(self, ipc):
        self.assertIsNone(rotation.reconcile_rotation(1, None))
        ipc.assert_called_once_with('-j', 'monitors')

    @patch.object(rotation, 'hypr', return_value='error: invalid configuration')
    def test_ipc_failure_is_not_recorded_as_success(self, _):
        with self.assertRaises(RuntimeError):
            rotation.apply_rotation('eDP-1', 1, True)


if __name__ == '__main__':
    unittest.main()
