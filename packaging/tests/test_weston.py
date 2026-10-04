"""Run directly; optionally pipe the pinned upstream installer on stdin."""
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / 'userpatches/overlay/install_components'
UPSTREAM = sys.stdin.read() if not sys.stdin.isatty() else ''


class WestonImageTest(unittest.TestCase):
    def test_supported_install_and_native_session(self):
        installer = (COMPONENTS / 'klipperscreen.sh').read_text()
        self.assertIn('BACKEND=W COMPOSITOR=weston', installer)
        self.assertIn('NETWORK=n START=0', installer)
        self.assertIn('Environment=GDK_BACKEND=wayland', installer)
        self.assertIn('Environment=LIBSEAT_BACKEND=seatd', installer)
        self.assertIn('/etc/xdg/weston/weston.ini', installer)
        self.assertNotIn('launch_KlipperScreen.sh', installer)

    def test_panel_specific_modes_are_not_hardcoded(self):
        config = (COMPONENTS / 'klipperscreen-weston.ini').read_text()
        self.assertIn('name=HDMI-A-1', config)
        self.assertIn('name=Unknown-1', config)
        self.assertEqual(config.count('mode=preferred'), 2)
        self.assertEqual(config.count('transform=normal'), 2)
        self.assertNotIn('1080', config)
        self.assertIn('xwayland=false', config)

    def test_tested_revision_and_device_permissions(self):
        versions = (COMPONENTS / 'software_versions.sh').read_text()
        self.assertIn('f2eb6919c0fcbcd4bab91ba59a5708415963d2ac', versions)
        self.assertIn('-G tty,dialout,render,video printer',
                      (COMPONENTS / 'prep_install.sh').read_text())

    @unittest.skipUnless(UPSTREAM, 'pipe pinned installer to exercise its backend selection')
    def test_upstream_selects_weston_without_prompt_or_cage(self):
        header = UPSTREAM.split('\ninstall_packages()', 1)[0]
        self.assertIn('install_graphical_backend()', header)
        script = header + '''
sudo() { printf 'MOCK_SUDO %s\\n' "$*"; }
BACKEND=W
COMPOSITOR=weston
install_graphical_backend
printf 'FINAL_BACKEND=%s\\n' "$BACKEND"
'''
        result = subprocess.run(['bash', '-c', script], input='', text=True,
                                capture_output=True, timeout=5, check=True)
        self.assertIn('MOCK_SUDO apt install -y weston seatd', result.stdout)
        self.assertIn('FINAL_BACKEND=W', result.stdout)
        self.assertNotIn('MOCK_SUDO apt install -y cage', result.stdout)


if __name__ == '__main__':
    unittest.main()
