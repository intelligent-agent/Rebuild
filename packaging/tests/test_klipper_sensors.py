"""Check explicit native-sensor configuration and unchanged Klipper safety."""
import configparser
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SensorConfigTest(unittest.TestCase):
    def test_templates_use_stock_objects_and_native_units(self):
        for ui in ("fluidd", "mainsail"):
            config = configparser.ConfigParser(interpolation=None)
            config.read(ROOT / f"userpatches/overlay/moonraker/moonraker-{ui}.conf")
            sensors = [s for s in config.sections() if s.startswith("sensor ")]
            self.assertEqual(set(sensors), {"sensor voltage", "sensor current"})
            for name, units in (("voltage", "V"), ("current", "A")):
                sensor = config[f"sensor {name}"]
                self.assertEqual(sensor["type"], "klipper")
                self.assertEqual(sensor["object"], f"temperature_sensor _{name}")
                self.assertEqual(sensor[f"parameter_{name}"].strip(), f"units={units}")
                for revision in ("a5", "a6", "a7", "a8"):
                    board = ROOT / f"packaging/rebuild-printer/usr/share/rebuild/klipper/config/generic-recore-{revision}.cfg"
                    self.assertIn(f"[temperature_sensor _{name}]", board.read_text())

    def test_only_electrical_sensor_headings_changed_in_klipper(self):
        for revision in ("a5", "a6", "a7", "a8"):
            path = f"packaging/rebuild-printer/usr/share/rebuild/klipper/config/generic-recore-{revision}.cfg"
            original = subprocess.check_output(
                ["git", "show", f"5b28c1cb90383bfdf85b2eb42dd4a6ee872702ef:{path}"],
                cwd=ROOT, text=True,
            )
            current = (ROOT / path).read_text()
            for name in ("voltage", "current", "fan_current"):
                original = original.replace(
                    f"[temperature_sensor {name}]", f"[temperature_sensor _{name}]"
                )
            self.assertEqual(current, original)

    def test_no_generator_or_startup_hook(self):
        installer = (ROOT / "userpatches/overlay/install_components/moonraker.sh").read_text()
        for text in ("rebuild-klipper-sensors", "ExecStartPre", "rebuild-sensors.conf"):
            self.assertNotIn(text, installer)
        self.assertFalse((ROOT / "userpatches/overlay/moonraker/rebuild-klipper-sensors").exists())

    def test_fork_pin_matches_both_configs(self):
        versions = (ROOT / "userpatches/overlay/install_components/software_versions.sh").read_text()
        pin = re.search(r'^MOONRAKER_VERSION="([0-9a-f]{40})"$', versions, re.M)[1]
        for ui in ("fluidd", "mainsail"):
            config = configparser.ConfigParser(interpolation=None)
            config.read(ROOT / f"userpatches/overlay/moonraker/moonraker-{ui}.conf")
            self.assertEqual(config["update_manager moonraker"]["pinned_commit"], pin)


if __name__ == "__main__":
    unittest.main()
