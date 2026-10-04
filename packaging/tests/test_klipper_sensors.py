"""Prototype configuration discovery; never rewrite Klipper ADC/safety settings."""
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "userpatches/overlay/moonraker/rebuild-klipper-sensors"
loader = importlib.machinery.SourceFileLoader("sensor_config", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class SensorConfigTest(unittest.TestCase):
    def test_all_board_templates_are_discovered_without_changes(self):
        for revision in ("a5", "a6", "a7", "a8"):
            source = ROOT / f"packaging/rebuild-printer/usr/share/rebuild/klipper/config/generic-recore-{revision}.cfg"
            original = source.read_bytes()
            with tempfile.TemporaryDirectory() as directory:
                cfg = Path(directory) / "printer.cfg"
                cfg.write_bytes(original)
                module.generate(directory)
                result = (Path(directory) / "rebuild-sensors.conf").read_text()
                self.assertIn("[sensor voltage]", result)
                self.assertIn("units=V", result)
                self.assertIn("[sensor current]", result)
                self.assertEqual("[sensor fan_current]" in result, revision in ("a7", "a8"))
                self.assertEqual(cfg.read_bytes(), original)

    def test_includes_hidden_names_cycles_and_repeat_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "printer.cfg").write_text("[include tool*.cfg]\n[temperature_sensor _voltage]\n")
            (root / "toolhead.cfg").write_text("[include printer.cfg]\n[temperature_sensor _remote_current]\n")
            module.generate(root)
            original = (root / "rebuild-sensors.conf").read_bytes()
            module.generate(root)
            result = (root / "rebuild-sensors.conf").read_text()
            self.assertIn("object: temperature_sensor _remote_current", result)
            self.assertIn("object: temperature_sensor _voltage", result)
            self.assertEqual((root / "rebuild-sensors.conf").read_bytes(), original)

    def test_no_sensors_and_user_file_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            module.generate(directory)
            target = Path(directory) / "rebuild-sensors.conf"
            self.assertNotIn("[sensor", target.read_text())
            target.write_text("# User configuration\n")
            with self.assertRaises(RuntimeError):
                module.generate(directory)
            self.assertEqual(target.read_text(), "# User configuration\n")


if __name__ == "__main__":
    unittest.main()
