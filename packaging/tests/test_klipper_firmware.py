import asyncio
import sys
import unittest
from unittest.mock import AsyncMock, patch
from types import SimpleNamespace
# Only BaseDeploy is replaced here; exercise the packaged adapter itself.
import importlib.util
import pathlib
import types
from unittest.mock import MagicMock

base = types.ModuleType('firmware_tests.update_manager.base_deploy')
class BaseDeploy:
    def notify_status(self, message, is_complete=False):
        self.cmd_helper.notify_update_response(message, is_complete)
base.BaseDeploy = BaseDeploy
sys.modules[base.__name__] = base
SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'rebuild-printer/usr/share/rebuild/moonraker/components/klipper_firmware.py'
spec = importlib.util.spec_from_file_location('firmware_tests.klipper_firmware', SOURCE)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
FirmwareUpdater, revision = module.FirmwareUpdater, module.revision



class Helper:
    def __init__(self, full=False):
        self.full = full
        self.messages = []
    def is_full_update(self):
        return self.full
    def notify_update_response(self, text, is_complete=False):
        self.messages.append((text, is_complete))
    def notify_update_refreshed(self):
        pass


class Server:
    def error(self, text):
        return RuntimeError(text)


def updater(full=False):
    u = object.__new__(FirmwareUpdater)
    u.host = 'v0.13.0-787-ge2b99a91'
    u.mcus = {'mcu': 'v0.13.0-786-g461c4e37', 'mcu ar100': 'v0.13.0-786-g461c4e37'}
    u.problem = ''
    u.prefix = ''
    u.server = Server()
    u.cmd_helper = Helper(full)
    return u


class Tests(unittest.IsolatedAsyncioTestCase):
    def test_revision(self):
        self.assertEqual(revision('v0.13.0-787-ge2b99a91-dirty-20261011_100000-recore'), 'v0.13.0-787-ge2b99a91')

    def test_mixed_mcus_remain_updateable(self):
        u = updater()
        u.mcus['mcu'] = u.host
        s = u.get_update_status()
        self.assertNotEqual(s['current_hash'], s['remote_hash'])
        u.mcus['mcu ar100'] = u.host
        s = u.get_update_status()
        self.assertEqual(s['current_hash'], s['remote_hash'])

    async def test_update_all_does_not_start_service(self):
        u = updater(True)
        u.run_service = AsyncMock()
        u.require_idle = AsyncMock()
        u.snapshot = AsyncMock()
        self.assertFalse(await u.update())
        u.require_idle.assert_not_called()
        u.snapshot.assert_not_called()
        u.run_service.assert_not_called()

    async def test_paused_printer_is_refused(self):
        u = updater()
        u.api = AsyncMock(return_value={'status': {'print_stats': {'state': 'paused'}, 'virtual_sdcard': {'is_active': False}, 'idle_timeout': {'state': 'Idle'}}})
        u.run_service = AsyncMock()
        with self.assertRaisesRegex(RuntimeError, 'refused'):
            await u.update()
        u.run_service.assert_not_called()

    async def test_unknown_idle_state_is_refused(self):
        u = updater()
        u.api = AsyncMock(side_effect=RuntimeError('Moonraker unavailable'))
        u.run_service = AsyncMock()
        with self.assertRaisesRegex(RuntimeError, 'unavailable'):
            await u.update()
        u.run_service.assert_not_called()

    async def test_service_failure_does_not_report_success(self):
        u = updater()
        u.require_idle = AsyncMock()
        u.snapshot = AsyncMock(return_value=(u.host, u.mcus))
        u.service_status = AsyncMock(return_value={'ActiveState': 'inactive'})
        u.run_service = AsyncMock(side_effect=RuntimeError('build failed'))
        u.reconnect = AsyncMock()
        with self.assertRaisesRegex(RuntimeError, 'build failed'):
            await u.update()
        u.reconnect.assert_not_called()
        self.assertFalse(any('SUCCESS' in text for text, _ in u.cmd_helper.messages))

    async def test_stale_firmware_after_reconnect_is_failure(self):
        u = updater()
        u.snapshot = AsyncMock(return_value=(u.host, u.mcus))
        with patch.object(module, 'time', SimpleNamespace(monotonic=iter([0, 0, 121]).__next__)), patch.object(module.asyncio, 'sleep', new=AsyncMock()):
            with self.assertRaisesRegex(RuntimeError, 'Firmware still differs'):
                await u.reconnect(u.host, u.mcus)

    async def test_reconnected_matching_mcus_succeed(self):
        u = updater()
        u.snapshot = AsyncMock(return_value=(u.host, {n: u.host for n in u.mcus}))
        await u.reconnect(u.host, u.mcus)
        self.assertTrue(all(v == u.host for v in u.mcus.values()))


if __name__ == '__main__':
    unittest.main()
