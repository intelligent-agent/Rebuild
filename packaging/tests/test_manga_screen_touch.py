"""The Manga Screen 2 must reach libinput as a touchscreen, not a touchpad."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
RULE = ROOT / 'packaging/rebuild-printer/usr/lib/udev/rules.d/61-manga-screen-touchscreen.rules'


class MangaScreenTouchTest(unittest.TestCase):
    def rule(self):
        lines = RULE.read_text().replace('\\\n', ' ').splitlines()
        return ' '.join(l for l in lines if l.strip() and not l.lstrip().startswith('#'))

    def test_matches_the_screen_by_usb_id(self):
        rule = self.rule()
        self.assertIn('ATTRS{idVendor}=="03eb"', rule)
        self.assertIn('ATTRS{idProduct}=="572b"', rule)

    def test_touchscreen_and_explicitly_not_touchpad(self):
        rule = self.rule()
        self.assertIn('ENV{ID_INPUT_TOUCHSCREEN}="1"', rule)
        # Empty is not enough: libinput counts anything but "0" as set.
        self.assertIn('ENV{ID_INPUT_TOUCHPAD}="0"', rule)

    def test_applies_to_the_parent_input_node_too(self):
        # libinput also reads the inputN parent; an event*-only rule left the
        # touchpad tag there and the screen stayed a touchpad.
        self.assertNotIn('KERNEL==', self.rule())

    def test_runs_after_input_id(self):
        # 60-input-id.rules sets the tags this overrides.
        self.assertGreater(int(RULE.name.split('-')[0]), 60)


if __name__ == '__main__':
    unittest.main()
