"""Exercise the packaged camera playback method without GTK or a display."""
import ast
from contextlib import suppress
import logging
from pathlib import Path
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
CAMERA = ROOT / 'packaging/rebuild-printer/usr/lib/rebuild/weston-camera.py'


class Player:
    def __init__(self, **kwargs):
        self.options = kwargs
        self.terminated = False

    def on_key_press(self, key):
        return lambda callback: callback

    def play(self, url):
        self.url = url

    def wait_for_playback(self):
        assert self.cache == 'no'
        assert self.demuxer_max_back_bytes == 0
        assert self.untimed is True
        assert self.audio == 'no'

    def terminate(self):
        self.terminated = True


class CameraTest(unittest.TestCase):
    def play(self, rotation, horizontal=False, vertical=False):
        tree = ast.parse(CAMERA.read_text())
        panel = next(n for n in tree.body if isinstance(n, ast.ClassDef))
        method = next(n for n in panel.body if isinstance(n, ast.FunctionDef) and n.name == 'play')
        players = []
        def create(**kwargs):
            players.append(Player(**kwargs))
            return players[-1]
        namespace = dict(logging=logging, suppress=suppress,
                         mpv=SimpleNamespace(MPV=create, ShutdownError=RuntimeError))
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(CAMERA), 'exec'), namespace)
        instance = SimpleNamespace(mpv=None, log=lambda *args: None,
                                   _printer=SimpleNamespace(cameras=[{}, {}]))
        cam = dict(stream_url='http://camera/stream', rotation=rotation,
                   flip_horizontal=horizontal, flip_vertical=vertical)
        namespace['play'](instance, None, cam)
        self.assertTrue(players[0].terminated)
        self.assertIsNone(instance.mpv)
        return players[0]

    def test_quarter_turns_and_cap_before_transform(self):
        for angle, expected in [(0, 'fps=15'), (90, 'fps=15,transpose=clock'),
                                (180, 'fps=15,hflip,vflip'),
                                (270, 'fps=15,transpose=cclock'),
                                (450, 'fps=15,transpose=clock')]:
            with self.subTest(angle=angle):
                self.assertEqual(self.play(angle).vf, expected)

    def test_arbitrary_rotation_and_flips_remain_supported(self):
        vf = self.play(37, True, True).vf
        self.assertTrue(vf.startswith('fps=15,hflip,vflip,rotate:'))
        self.assertAlmostEqual(float(vf.split('rotate:')[1]), 37 * 3.14159 / 180)

    def test_no_diagnostic_thread_in_packaged_panel(self):
        self.assertNotIn('monitor_stop', CAMERA.read_text())

    def test_runtime_adapter_and_clean_checkout_launcher(self):
        installer = (ROOT / 'userpatches/overlay/install_components/klipperscreen.sh').read_text()
        self.assertIn('OPTIONAL="fonts-nanum fonts-ipafont libmpv2"', installer)
        self.assertIn('sha256sum -c -', installer)
        self.assertIn('weston-camera-launch.py', installer)
        launcher = CAMERA.with_name('weston-camera-launch.py').read_text()
        self.assertIn('CAMERA_SHA256', launcher)
        self.assertIn('using stock camera', launcher)
        self.assertIn('runpy.run_path', launcher)


if __name__ == '__main__':
    unittest.main()
