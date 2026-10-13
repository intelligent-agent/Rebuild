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
module.HELPER = SOURCE.parents[4] / 'lib/rebuild/firmware-kconfig.py'
import tempfile



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

    def test_build_suffix_accepts_hyphenated_hostnames(self):
        target = 'v0.13.0-787-ge2b99a91'
        for hostname in ('recore', 'recore-voron', 'recore-kossel-a6', 'recore-a6.local'):
            for dirty in ('', '-dirty'):
                with self.subTest(hostname=hostname, dirty=dirty):
                    self.assertEqual(revision(target + dirty + '-20261012_193607-' + hostname), target)
        self.assertNotEqual(revision('v0.13.0-786-g461c4e37-20261012_193607-recore-voron'), target)

    def test_build_script_uses_same_revision_comparison(self):
        source = (SOURCE.parents[4] / 'bin/rebuild-firmware').read_text()
        block = source.split("<<'PYFLASH'", 1)[1].split('PYFLASH', 1)[0]
        import ast
        function = next(node for node in ast.parse(block).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'rev')
        namespace = {'re': __import__('re')}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<needs_flash>', 'exec'), namespace)
        for value in ('v0.13.0-787-ge2b99a91-dirty',
                      'v0.13.0-787-ge2b99a91-20261012_193607-recore-voron',
                      'v0.13.0-786-g461c4e37-20261012_193607-recore-kossel-a6'):
            self.assertEqual(namespace['rev'](value), revision(value))

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


class ConfigTests(unittest.IsolatedAsyncioTestCase):
    """Edited firmware options (#159): the entry follows the override files."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.dir.name)
        self.user, self.records = root / 'firmware', root / 'opt'
        self.user.mkdir()
        self.records.mkdir()
        self.patches = [patch.object(module, 'USERDIR', self.user), patch.object(module, 'RECORDS', self.records)]
        for p in self.patches:
            p.start()
        self.u = updater()
        self.u.mcus = {n: self.u.host for n in self.u.mcus}
        self.u.roles = {'stm32'}

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.dir.cleanup()

    def current(self):
        s = self.u.get_update_status()
        return s['current_hash'] == s['remote_hash'], s

    def flashed(self, text):
        """What rebuild-firmware records after flashing a build of this file."""
        (self.user / 'stm32.config').write_text(text)
        (self.records / 'stm32.applied').write_text(module.user_digest(self.user / 'stm32.config') + '\n')

    def test_stock_install_is_current(self):
        ok, s = self.current()
        self.assertTrue(ok)
        self.assertEqual(s['commits_behind'], [])

    def test_starter_file_with_only_comments_is_not_a_change(self):
        (self.user / 'stm32.config').write_text('# Your changes\n# CONFIG_WANT_BUTTONS=n\n\n')
        self.assertTrue(self.current()[0])

    def test_edit_at_same_klipper_revision_offers_an_update(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        ok, s = self.current()
        self.assertFalse(ok)
        self.assertEqual(s['commits_behind_count'], 1)
        self.assertIn('stm32.config', s['commits_behind'][0]['subject'])
        self.assertIn('stm32.config', s['remote_version'])
        self.assertTrue(s['warnings'])

    def test_flashed_edit_is_current_and_comments_stay_free(self):
        self.flashed('CONFIG_WANT_BUTTONS=n\n')
        self.assertTrue(self.current()[0])
        (self.user / 'stm32.config').write_text('# note to self\nCONFIG_WANT_BUTTONS=n\n')
        self.assertTrue(self.current()[0])

    def test_reverting_or_removing_a_flashed_override_offers_an_update(self):
        self.flashed('CONFIG_WANT_BUTTONS=n\n')
        (self.user / 'stm32.config').write_text('# CONFIG_WANT_BUTTONS=n\n')
        self.assertFalse(self.current()[0])
        (self.user / 'stm32.config').unlink()
        self.assertFalse(self.current()[0])

    def test_edit_and_revert_before_building_is_no_change(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        self.assertFalse(self.current()[0])
        (self.user / 'stm32.config').write_text('')
        self.assertTrue(self.current()[0])

    def test_only_roles_on_this_board_count(self):
        (self.user / 'rp2040.config').write_text('CONFIG_X=y\n')
        self.assertTrue(self.current()[0])

    def test_revision_and_config_both_listed(self):
        self.u.mcus['mcu'] = 'v0.13.0-786-g461c4e37'
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        self.assertEqual(self.u.get_update_status()['commits_behind_count'], 2)

    def test_option_order_matters_comments_do_not(self):
        a, b = self.user / 'a', self.user / 'b'
        a.write_text('CONFIG_A=y\nCONFIG_A=n\n')
        b.write_text('CONFIG_A=n\nCONFIG_A=y\n')
        self.assertNotEqual(module.user_digest(a), module.user_digest(b))

    async def run_update(self, applied_after):
        u = self.u
        u.require_idle = AsyncMock()
        u.snapshot = AsyncMock(return_value=(u.host, u.mcus))
        u.service_status = AsyncMock(return_value={'ActiveState': 'inactive'})
        async def build():
            if applied_after is not None:
                (self.records / 'stm32.applied').write_text(applied_after)
        u.run_service = AsyncMock(side_effect=build)
        u.reconnect = AsyncMock()
        return await u.update()

    async def test_update_succeeds_only_once_the_edit_is_recorded(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        digest = module.user_digest(self.user / 'stm32.config')
        self.assertTrue(await self.run_update(digest))
        self.assertTrue(self.current()[0])
        self.assertTrue(any('SUCCESS' in t for t, _ in self.u.cmd_helper.messages))

    async def test_matching_revisions_do_not_prove_the_edit_applied(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        with self.assertRaisesRegex(RuntimeError, 'not built from the current stm32.config'):
            await self.run_update(None)
        self.assertFalse(any('SUCCESS' in t for t, _ in self.u.cmd_helper.messages))
        self.assertFalse(self.current()[0])

    async def test_edit_saved_again_during_the_build_is_not_a_failure(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        newer = (self.user / 'stm32.config')
        async def build():
            newer.write_text('CONFIG_WANT_BUTTONS=y\n')
            (self.records / 'stm32.applied').write_text(module.user_digest(newer))
        self.u.require_idle = AsyncMock()
        self.u.snapshot = AsyncMock(return_value=(self.u.host, self.u.mcus))
        self.u.service_status = AsyncMock(return_value={'ActiveState': 'inactive'})
        self.u.run_service = AsyncMock(side_effect=build)
        self.u.reconnect = AsyncMock()
        self.assertTrue(await self.u.update())

    async def test_failed_build_leaves_the_update_available(self):
        (self.user / 'stm32.config').write_text('CONFIG_WANT_BUTTONS=n\n')
        self.u.require_idle = AsyncMock()
        self.u.snapshot = AsyncMock(return_value=(self.u.host, self.u.mcus))
        self.u.service_status = AsyncMock(return_value={'ActiveState': 'inactive'})
        self.u.run_service = AsyncMock(side_effect=RuntimeError('build failed: does not fit'))
        with self.assertRaisesRegex(RuntimeError, 'does not fit'):
            await self.u.update()
        self.assertFalse(self.current()[0])

    def test_file_notice_only_for_firmware_overrides(self):
        k = object.__new__(module.KlipperFirmware)
        k.notify = None
        k.manager = SimpleNamespace(cmd_helper=SimpleNamespace(notify_update_refreshed=lambda: None))
        calls = []
        class Loop:
            def call_later(self, delay, fn):
                calls.append(delay)
                return SimpleNamespace(cancel=lambda: None)
        with patch.object(module.asyncio, 'get_running_loop', return_value=Loop()):
            k.on_files({'item': {'root': 'config', 'path': 'printer.cfg'}})
            k.on_files({'item': {'root': 'gcodes', 'path': 'firmware/x'}})
            self.assertEqual(calls, [])
            k.on_files({'item': {'root': 'config', 'path': 'firmware/stm32.config'}})
            self.assertEqual(len(calls), 1)

    def test_digest_command_matches_the_updater(self):
        import subprocess
        (self.user / 'stm32.config').write_text('# c\nCONFIG_WANT_BUTTONS=n\n')
        out = subprocess.check_output([sys.executable, str(module.HELPER), 'digest', str(self.user / 'stm32.config')], text=True).strip()
        self.assertEqual(out, module.user_digest(self.user / 'stm32.config'))
        self.assertEqual(module.user_digest(self.user / 'missing'), 'stock')


if __name__ == '__main__':
    unittest.main()
