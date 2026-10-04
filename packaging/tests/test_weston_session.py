"""Exercise the session configurator in an isolated filesystem, not on the host."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'packaging/rebuild-printer/usr/lib/rebuild/configure-weston-session'


class SessionTest(unittest.TestCase):
    def run_helper(self, root, live=False):
        script = HELPER.read_text()
        for path in ['/etc/systemd/system', '/var/lib/systemd', '/run/systemd/system']:
            script = script.replace(path, str(root) + path)
        if live:
            (root / 'run/systemd/system').mkdir(parents=True, exist_ok=True)
        mocks = '''
id() { test "$*" = '-u printer' && printf '2200\\n'; }
loginctl() { printf 'LOGINCTL %s\\n' "$*"; }
'''
        return subprocess.run(['sh', '-c', mocks + script], text=True,
                              capture_output=True, check=True, timeout=5)

    def test_offline_image_and_uid_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_helper(root)
            conf = (root / 'etc/systemd/system/KlipperScreen.service.d/weston-containment.conf').read_text()
            self.assertIn('Requires=user-runtime-dir@2200.service', conf)
            self.assertIn('After=user-runtime-dir@2200.service', conf)
            self.assertIn('PAMName=\n', conf)
            self.assertTrue((root / 'var/lib/systemd/linger/printer').is_file())
            self.assertNotIn('LOGINCTL', result.stdout)

    def test_live_install_and_repeatability(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for _ in range(2):
                result = self.run_helper(root, live=True)
                self.assertIn('LOGINCTL enable-linger printer', result.stdout)


if __name__ == '__main__':
    unittest.main()
