import importlib.machinery
import importlib.util
import pathlib
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

HELPER = pathlib.Path(__file__).resolve().parents[1] / 'rebuild-printer/usr/lib/rebuild/klipper-stop'
loader = importlib.machinery.SourceFileLoader('klipper_stop', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
stop = importlib.util.module_from_spec(spec)
loader.exec_module(stop)


class FakeClient:
    def __init__(self, registers):
        self.deadline = time.monotonic() + 2
        self.output = []
        self.commands = []
        self.registers = iter(registers)

    def query(self, objects):
        return {'webhooks': {'state': 'ready'},
                'configfile': {'settings': {
                    'stepper_x': {}, 'tmc2209 stepper_x': {}}},
                'stepper_enable': {'steppers': {'stepper_x': False}},
                'heaters': {'available_heaters': ['heater_bed']},
                'heater_bed': {'target': 0, 'power': 0}}

    def call(self, method, params):
        assert method == 'gcode/subscribe_output'

    def script(self, command):
        self.commands.append(command)
        if command.startswith('DUMP_TMC'):
            self.output.append('CHOPCONF: %08x' % next(self.registers))


class Tests(unittest.TestCase):
    def test_wait_for_register_not_just_logical_state(self):
        client = FakeClient([3, 0])
        with patch.object(stop, 'log'):
            stop.cleanup(client)
        self.assertEqual(client.commands[0], 'TURN_OFF_HEATERS\nM84\nM400')
        self.assertEqual(len(client.commands), 3)

    def test_overridden_commands_rejected(self):
        for command in stop.COMMANDS:
            with self.assertRaises(RuntimeError):
                stop.check_overrides({'gcode_macro ' + command.lower(): {}})

    def test_dedicated_pin_not_checked_via_toff(self):
        settings = {'stepper_x': {'enable_pin': '!PL12'},
                    'tmc2209 stepper_x': {}, 'stepper_y': {},
                    'tmc2209 stepper_y': {}}
        self.assertEqual(stop.virtual_drivers(settings, ['stepper_x', 'stepper_y']),
                         ['stepper_y'])

    def test_unknown_virtual_driver_rejected(self):
        with self.assertRaises(RuntimeError):
            stop.virtual_drivers({'stepper_x': {}, 'tmc9999 stepper_x': {}},
                                 ['stepper_x'])

    def test_missing_socket_fails_promptly(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['python3', str(HELPER), '--socket',
                                     directory + '/missing', '--timeout', '.2'],
                                    capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 1)
        self.assertIn('WARNING', result.stdout)

    def test_service_contains_stop_hook(self):
        service = HELPER.parents[5] / 'userpatches/overlay/install_components/klipper.sh'
        self.assertIn('ExecStop=/usr/bin/python3 /usr/lib/rebuild/klipper-stop',
                      service.read_text())


if __name__ == '__main__':
    unittest.main()
