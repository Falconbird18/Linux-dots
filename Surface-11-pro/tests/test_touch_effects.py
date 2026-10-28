import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('effects', Path(__file__).parents[1] / 'input/touch-effects.py')
effects = importlib.util.module_from_spec(spec)
spec.loader.exec_module(effects)


class Gestures(unittest.TestCase):
    def setUp(self):
        self.swipe = effects.Swipe()

    def event(self, kind, key, x=0.5, y=0.5, now=0.1):
        return self.swipe.event(dict(kind=kind, id=key, x=x, y=y), now)

    def fingers(self, count=3):
        for key in range(count):
            self.event('down', key)

    def move(self, x, y=0.5, now=0.4):
        return [self.event('move', key, x, y, now) for key in range(3)]

    def test_three_fingers_left_and_right(self):
        self.fingers()
        self.assertEqual(self.move(0.35)[-1], '+1')
        self.assertEqual(self.move(0.2), [None]*3)
        for key in range(3):
            self.event('up', key)
        self.fingers()
        self.assertEqual(self.move(0.65)[-1], '-1')

    def test_one_two_and_four_fingers_do_not_switch(self):
        for count in (1, 2, 4):
            self.setUp()
            self.fingers(count)
            self.assertEqual(self.move(0.35), [None]*3)

    def test_vertical_pinch_and_small_motion_do_not_switch(self):
        self.fingers()
        self.assertEqual(self.move(0.48, y=0.7), [None]*3)
        self.assertEqual(self.move(0.45), [None]*3)
        self.assertIsNone(self.event('move', 0, 0.2))

    def test_slow_and_cancelled_swipes_do_not_switch(self):
        self.fingers()
        self.assertEqual(self.move(0.35, now=2), [None]*3)
        self.setUp()
        self.fingers()
        self.event('cancel', 0)
        self.assertEqual(self.move(0.35), [None]*3)

    def test_fingers_must_arrive_together(self):
        self.event('down', 0, now=0)
        self.event('down', 1, now=0.1)
        self.event('down', 2, now=0.5)
        self.assertEqual(self.move(0.35, now=0.8), [None]*3)


if __name__ == '__main__':
    unittest.main()
