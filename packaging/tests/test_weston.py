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
        self.assertIn('KLIPPERSCREEN_VERSION="973c95dd4d8a5c98b77cd94c48dde667048d43e9"', versions)
        self.assertIn('-G tty,dialout,render,video printer',
                      (COMPONENTS / 'prep_install.sh').read_text())

    def test_service_containment_and_runtime_lifetime(self):
        helper = (ROOT / 'packaging/rebuild-printer/usr/lib/rebuild/configure-weston-session').read_text()
        self.assertIn('printer_uid=$(id -u printer)', helper)
        self.assertIn('PAMName=', helper)
        self.assertIn('KillMode=control-group', helper)
        self.assertIn('Requires=user-runtime-dir@${printer_uid}.service', helper)
        self.assertIn('/var/lib/systemd/linger/printer', helper)
        self.assertIn('loginctl enable-linger printer', helper)
        self.assertNotIn('pkill', helper)
        self.assertNotIn('systemctl restart', helper)
        self.assertIn('sh /usr/lib/rebuild/configure-weston-session',
                      (COMPONENTS / 'klipperscreen.sh').read_text())
        postinst = (ROOT / 'packaging/debian/rebuild-printer.postinst').read_text()
        self.assertIn('sh /usr/lib/rebuild/configure-weston-session', postinst)

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
