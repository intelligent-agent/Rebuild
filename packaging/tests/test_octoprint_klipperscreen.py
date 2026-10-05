"""Static integration checks; physical/job-control checks still need the image."""
import configparser
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / 'userpatches/overlay'


def read_config(path):
    config = configparser.ConfigParser(interpolation=None)
    config.read(path)
    return config


class OctoprintKlipperScreenTest(unittest.TestCase):
    def test_reuses_existing_installers_without_toggle(self):
        text = (ROOT / 'armbian/customize-image-octoprint.sh').read_text()
        for component in ('moonraker', 'klipperscreen'):
            self.assertIn(f'source /tmp/overlay/install_components/{component}.sh', text)
        calls = [line.strip() for line in text.splitlines() if line.startswith('install_')]
        self.assertLess(calls.index('install_octoprint'), calls.index('install_moonraker "octoprint"'))
        self.assertLess(calls.index('install_moonraker "octoprint"'), calls.index('install_klipperscreen'))
        self.assertNotIn('install_toggle', calls)
        self.assertNotIn('install_weston', calls)  # Stock KlipperScreen owns its compositor.

    def test_shared_upload_directory(self):
        klipper = read_config(OVERLAY / 'octoprint/octoprint-moonraker.cfg')
        path = klipper['virtual_sdcard']['path']
        self.assertEqual(path, '/home/printer/printer_data/gcodes')
        self.assertIn(f'  uploads: {path}', (OVERLAY / 'octoprint/config.yaml').read_text())
        for section in ('pause_resume', 'display_status', 'rebuild_firmware'):
            self.assertIn(section, klipper)
        self.assertEqual(klipper['virtual_sdcard']['on_error_gcode'], 'TURN_OFF_HEATERS')

    def test_cancel_turns_heaters_off_without_printer_specific_moves(self):
        config = read_config(OVERLAY / 'octoprint/octoprint-moonraker.cfg')
        cancel = config['gcode_macro CANCEL_PRINT']
        self.assertEqual(cancel['rename_existing'], 'CANCEL_PRINT_BASE')
        self.assertEqual(cancel['gcode'].split(), ['TURN_OFF_HEATERS', 'CANCEL_PRINT_BASE'])

    def test_local_backend_and_camera(self):
        config = read_config(OVERLAY / 'moonraker/moonraker-octoprint.conf')
        self.assertEqual(config['server']['klippy_uds_address'], '/tmp/klippy_uds')
        self.assertEqual(config['server']['port'], '7125')
        self.assertEqual(config['authorization']['trusted_clients'].split(), ['127.0.0.0/8', '::1/128'])
        self.assertEqual(config['webcam Recore']['service'], 'ustreamer')
        self.assertEqual(config['webcam Recore']['stream_url'], 'http://127.0.0.1:8080/?action=stream')
        self.assertIn('update_manager KlipperScreen', config)
        self.assertNotIn('update_manager fluidd', config)
        self.assertNotIn('update_manager mainsail', config)

    def test_no_toggle_autologin(self):
        text = (OVERLAY / 'octoprint/config.yaml').read_text()
        self.assertIn('autologinLocal: false', text)
        self.assertNotIn('autologinAs:', text)
        self.assertIn('    port: /tmp/printer', text)


if __name__ == '__main__':
    unittest.main()
