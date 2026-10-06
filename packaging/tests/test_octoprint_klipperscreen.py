"""Static integration checks; physical/job-control checks still need the image."""
import configparser
import os
import subprocess
import tempfile
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


class OctoprintPluginOwnershipTest(unittest.TestCase):
    """Plugins installed as root broke OctoPrint's own plugin updates (#126)."""
    SCRIPT = ROOT / 'packaging/rebuild-printer/usr/lib/rebuild/octoprint-venv-owner'

    def test_image_installs_plugins_with_pip_then_hands_venv_over(self):
        text = (OVERLAY / 'install_components/octoprint.sh').read_text()
        self.assertNotIn('setup.py install', text)
        # OctoKlipper's setup.py imports OctoPrint's setuptools helpers: an
        # isolated build cannot see them and fails.
        for plugin in ('OctoprintKlipperPlugin', 'OctoPrint-TopTemp', 'octoprint_recore'):
            self.assertIn('pip install --no-build-isolation ./' + plugin, text)
        last_plugin = text.rindex('pip install --no-build-isolation ./octoprint_recore')
        handover = text.index('chown -R ${USER}:${USER} ${HOMEDIR}/OctoPrint ', last_plugin)
        self.assertGreater(handover, last_plugin)

    def test_postinst_repairs_existing_boards(self):
        text = (ROOT / 'packaging/debian/rebuild-printer.postinst').read_text()
        self.assertIn('/usr/lib/rebuild/octoprint-venv-owner', text)

    def run_script(self, venv, owner):
        subprocess.run(['sh', str(self.SCRIPT), str(venv), owner], check=True)

    def test_removes_half_uninstalled_leftovers_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'lib/python3.13/site-packages'
            for name in ('~ctoprint_klipper', '~ctoKlipper-0.3.9.5-py3.13.egg-info',
                         'octoprint_klipper', 'octoklipper-0.4.dist-info'):
                (site / name).mkdir(parents=True)
                (site / name / 'file').write_text('x')
            self.run_script(tmp, os.environ.get('USER') or 'root')
            self.assertEqual(sorted(p.name for p in site.iterdir()),
                             ['octoklipper-0.4.dist-info', 'octoprint_klipper'])

    def test_missing_venv_is_not_an_error(self):
        self.run_script('/nonexistent/venv', 'root')

    @unittest.skipUnless(os.geteuid() == 0, 'chown needs root')
    def test_gives_root_owned_files_to_the_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / 'lib/python3.13/site-packages/Top_Temp-0.0.2.5-py3.13.egg-info'
            f.parent.mkdir(parents=True)
            f.write_text('x')
            self.run_script(tmp, 'nobody')
            self.assertEqual(f.owner(), 'nobody')
