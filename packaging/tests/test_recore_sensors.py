import importlib.util
import math
import pathlib
import sys
import types
import unittest
from collections import defaultdict, deque
from unittest.mock import AsyncMock

# Minimal Moonraker protocol; live integration also exercises its real sensor
# registry, endpoints, sampling timer and configuration metadata.
base = types.ModuleType('voltage_tests.sensor')
class BaseSensor:
    def __init__(self, config):
        self.server = config.get_server()
        self.id = 'recore_sensors'
        self.param_info = [{'name': 'voltage', 'units': 'V'}]
        self.last_measurements = {}
        self.last_value = {}
        self.values = defaultdict(lambda: deque(maxlen=1200))
base.BaseSensor = BaseSensor
sys.modules[base.__name__] = base
SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'rebuild-printer/usr/share/rebuild/moonraker/components/recore_sensors.py'
spec = importlib.util.spec_from_file_location('voltage_tests.recore_sensors', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Config:
    def __init__(self, server):
        self.server = server
        self.parsed = {}
    def get_server(self):
        return self.server
    def get(self, name, default=None):
        return default
    def error(self, text):
        return RuntimeError(text)

class Server:
    def __init__(self):
        self.sensor = types.SimpleNamespace(sensors={})
        self.api = types.SimpleNamespace(get_object_list=AsyncMock(return_value=['temperature_sensor voltage']), subscribe_objects=AsyncMock(return_value={
            'temperature_sensor voltage': {'temperature': 24.1}}))
        self.events = {}
    def load_component(self, config, name):
        assert name == 'sensor'
        return self.sensor
    def lookup_component(self, name):
        assert name == 'klippy_apis'
        return self.api
    def register_event_handler(self, name, cb):
        self.events[name] = cb

class Tests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.server = Server()
        self.config = Config(self.server)
        self.sensor = module.load_component(self.config)

    def test_frontend_registration_and_unit_metadata(self):
        self.assertIs(self.server.sensor.sensors['recore_sensors'], self.sensor)
        self.assertEqual(self.config.parsed['sensor recore_sensors'],
                         {'parameter_voltage': {'units': 'V'}})
        self.assertEqual(self.sensor.last_measurements, {})

    async def test_initial_and_partial_updates(self):
        await self.sensor.on_ready()
        self.server.api.subscribe_objects.assert_awaited_once_with(
            {'temperature_sensor voltage': ['temperature']})
        self.assertEqual(self.sensor.last_measurements, {'voltage': 24.1})
        self.sensor.on_status({'toolhead': {'position': [0, 0, 0]}})
        self.sensor.on_status({'temperature_sensor voltage': {'measured_min_temp': 20}})
        self.assertEqual(self.sensor.last_measurements, {'voltage': 24.1})
        self.sensor.on_status({'temperature_sensor voltage': {'temperature': 23.8}})
        self.assertEqual(self.sensor.last_measurements, {'voltage': 23.8})

    async def test_shutdown_and_disconnect_clear_stale_values(self):
        for event in ('server:klippy_shutdown', 'server:klippy_disconnect'):
            await self.sensor.on_ready()
            self.sensor.values['voltage'].append(24.1)
            self.server.events[event]()
            self.sensor.on_status({'temperature_sensor voltage': {'temperature': 23}})
            self.assertEqual(self.sensor.last_measurements, {})
            self.assertEqual(dict(self.sensor.values), {})
        await self.sensor.on_ready()
        self.assertEqual(self.sensor.last_measurements, {'voltage': 24.1})

    async def test_unavailable_source_is_not_reported_as_zero(self):
        self.server.api.subscribe_objects.return_value = {}
        await self.sensor.on_ready()
        self.assertEqual(self.sensor.last_measurements, {})

    async def test_new_hidden_adc_source_is_preferred(self):
        self.server.api.get_object_list.return_value = [
            'temperature_sensor voltage', 'temperature_sensor _voltage']
        self.server.api.subscribe_objects.return_value = {
            'temperature_sensor _voltage': {'temperature': 24.2}}
        await self.sensor.on_ready()
        self.assertEqual(self.sensor.last_measurements, {'voltage': 24.2})
        self.server.api.subscribe_objects.assert_awaited_once_with(
            {'temperature_sensor _voltage': ['temperature']})

    async def test_config_without_recore_adc_remains_unavailable(self):
        self.server.api.get_object_list.return_value = ['extruder']
        with self.assertLogs(level='WARNING'):
            await self.sensor.on_ready()
        self.server.api.subscribe_objects.assert_not_awaited()
        self.assertEqual(self.sensor.last_measurements, {})

    async def test_invalid_readings_are_not_published(self):
        await self.sensor.on_ready()
        for value in (None, '24', True, math.nan, math.inf):
            self.sensor.on_status({'temperature_sensor voltage': {'temperature': value}})
            self.assertEqual(self.sensor.last_measurements, {})

    async def test_failed_reconnect_removes_previous_reading(self):
        await self.sensor.on_ready()
        self.server.api.subscribe_objects.side_effect = RuntimeError('offline')
        with self.assertLogs(level='ERROR'):
            await self.sensor.on_ready()
        self.assertEqual(self.sensor.last_measurements, {})
        self.assertFalse(self.sensor.connected)

    def test_user_sensor_name_collision_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            module.load_component(self.config)

if __name__ == '__main__':
    unittest.main()
