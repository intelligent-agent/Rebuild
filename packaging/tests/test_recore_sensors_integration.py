"""Exercise the bridge against real Moonraker sensor code (pinned and updated)."""
import importlib.util
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

SOURCE = os.environ.get('MOONRAKER_TEST_SOURCE')
BRIDGE = Path(__file__).resolve().parents[1] / 'rebuild-printer/usr/share/rebuild/moonraker/components/recore_sensors.py'

@unittest.skipUnless(SOURCE, 'set MOONRAKER_TEST_SOURCE for real Moonraker integration')
class Integration(unittest.IsolatedAsyncioTestCase):
    async def test_registration_sampling_notifications_units_and_reconnect(self):
        sys.path.insert(0, SOURCE)
        from moonraker.components.sensor import Sensors
        spec = importlib.util.spec_from_file_location('moonraker.components.recore_sensors', BRIDGE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        events, notifications, endpoints = {}, [], {}
        registry = {}
        api = SimpleNamespace(
            get_object_list=AsyncMock(return_value=['temperature_sensor _voltage']),
            subscribe_objects=AsyncMock(return_value={
                'temperature_sensor _voltage': {'temperature': 24.1}}))
        server = SimpleNamespace(
            lookup_component=lambda name: api if name == 'klippy_apis' else SimpleNamespace(),
            register_event_handler=lambda name, cb: events.update({name: cb}),
            get_event_loop=lambda: SimpleNamespace(register_timer=lambda cb: SimpleNamespace(start=lambda: None)),
            register_endpoint=lambda name, methods, cb: endpoints.update({name: cb}),
            register_notification=lambda name: None,
            send_event=lambda name, data: notifications.append((name, data)),
            add_warning=lambda *args, **kwargs: self.fail(str(args)))
        class Config:
            parsed = {}
            error = RuntimeError
            def get_server(self): return server
            def get_name(self): return 'recore_sensors'
            def get(self, name, default=None): return {'type':'Recore','name':'Input voltage'}.get(name, default)
            def getint(self, name, default=None): return default
            def get_options(self): return {'parameter_voltage':'units=V'}
            def getdict(self, name): return {'units':'V'}
            def get_prefix_sections(self, prefix): return []
        config = Config()
        def load_component(config, name):
            self.assertEqual(name, 'sensor')
            if name not in registry: registry[name] = Sensors(config)
            return registry[name]
        server.load_component = load_component
        bridge = module.load_component(config)
        sensors = registry['sensor']
        await sensors.component_init()
        await events['server:klippy_ready']()
        request = SimpleNamespace(get_boolean=lambda name, default: True)
        result = await endpoints['/server/sensors/list'](request)
        info = result['sensors']['recore_sensors']
        self.assertEqual(info['values'], {'voltage':24.1})
        self.assertEqual(info['friendly_name'], 'Input voltage')
        self.assertEqual(info['parameter_info'], [{'units':'V','name':'voltage'}])
        self.assertEqual(config.parsed['sensor recore_sensors']['parameter_voltage'], {'units':'V'})
        sensors._update_sensor_values(1.0)
        self.assertEqual(bridge.get_sensor_measurements(), {'voltage':[24.1]})
        self.assertEqual(notifications[-1], ('sensors:sensor_update', {'recore_sensors':{'voltage':24.1}}))
        events['server:klippy_disconnect']()
        sensors._update_sensor_values(2.0)
        self.assertEqual(notifications[-1], ('sensors:sensor_update', {'recore_sensors':{}}))
        self.assertEqual(bridge.get_sensor_measurements(), {})
        await events['server:klippy_ready']()
        sensors._update_sensor_values(3.0)
        self.assertEqual(bridge.get_sensor_measurements(), {'voltage':[24.1]})

if __name__ == '__main__':
    unittest.main()
