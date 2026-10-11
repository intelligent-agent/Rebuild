"""Build and flash Klipper MCU firmware through Moonraker update clients."""
import asyncio
import hashlib
import json
import pathlib
import re
import time
from urllib.parse import quote
from tornado.httpclient import AsyncHTTPClient
from .update_manager.base_deploy import BaseDeploy

NAME = 'Klipper firmware'
LOG = pathlib.Path('/home/printer/printer_data/logs/rebuild-firmware.log')
SERVICE = 'rebuild-firmware'


def revision(value):
    value = re.sub(r'-\d{8}_\d{6}-[^-]+$', '', value)
    return value.removesuffix('-dirty')


def fingerprint(versions):
    return hashlib.sha256(json.dumps(versions, sort_keys=True).encode()).hexdigest()


class FirmwareUpdater(BaseDeploy):
    def __init__(self, config):
        super().__init__(config, name=NAME)
        self.host = ''
        self.mcus = {}
        self.problem = ''

    async def api(self, path):
        result = await AsyncHTTPClient().fetch('http://127.0.0.1:7125' + path, request_timeout=5)
        return json.loads(result.body)['result']

    async def snapshot(self):
        info = await self.api('/printer/info')
        if info.get('state') != 'ready':
            raise self.server.error('Klipper is not ready; cannot verify MCU firmware')
        objects = (await self.api('/printer/objects/list'))['objects']
        names = sorted(n for n in objects if n == 'mcu' or n.startswith('mcu '))
        if not names:
            raise self.server.error('No configured MCUs were found')
        status = (await self.api('/printer/objects/query?' + '&'.join(quote(n) for n in names)))['status']
        host = revision(info.get('software_version', ''))
        versions = {n: revision(status[n].get('mcu_version', '')) for n in names}
        if not host or any(not v or v == '?' for v in versions.values()):
            raise self.server.error('Cannot read the host or MCU firmware versions')
        return host, versions

    async def refresh(self):
        try:
            self.host, self.mcus = await self.snapshot()
            self.problem = ''
        except Exception as e:
            self.problem = str(e)
        self._save_state()

    def get_update_status(self):
        actual = fingerprint(self.mcus)
        wanted = fingerprint({n: self.host for n in self.mcus})
        warnings = [self.problem] if self.problem else []
        if self.mcus and actual != wanted:
            warnings.append('Firmware differs from installed Klipper. Use this Update button to rebuild and flash. Update all leaves firmware unchanged.')
        summary = ', '.join(n + ': ' + v for n, v in self.mcus.items()) or 'MCU versions unavailable'
        return dict(
            configured_type='git_repo', detected_type='git_repo',
            is_valid=True, is_dirty=False, pristine=True, corrupt=False,
            version=summary, remote_version=self.host, full_version_string=summary,
            current_hash=actual, remote_hash=wanted,
            remote_url='?', branch='installed Klipper', channel='dev',
            commits_behind=[], commits_behind_count=0, git_messages=[],
            warnings=warnings, anomalies=[], info_tags=[]
        )

    async def command(self, *args):
        process = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
        )
        output, _ = await process.communicate()
        if process.returncode:
            raise self.server.error(output.decode(errors='replace').strip() or 'Command failed')
        return output.decode(errors='replace')

    async def service_status(self):
        text = await self.command(
            '/bin/systemctl', 'show', SERVICE,
            '--property=ActiveState,SubState,Result,ExecMainStatus'
        )
        return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)

    async def require_idle(self):
        status = (await self.api('/printer/objects/query?print_stats&virtual_sdcard&idle_timeout'))['status']
        if (status['print_stats']['state'] in ('printing', 'paused')
                or status['virtual_sdcard']['is_active']
                or status['idle_timeout']['state'] == 'Printing'):
            raise self.server.error('Firmware update refused: printer is printing, paused or moving')

    async def run_service(self):
        offset = LOG.stat().st_size if LOG.exists() else 0
        await self.command('sudo', '-n', '/bin/systemctl', 'start', SERVICE)
        started = time.monotonic()
        heartbeat = started
        buffered = ''
        while True:
            if LOG.exists():
                with LOG.open('rb') as f:
                    if f.seek(0, 2) < offset:
                        offset = 0
                    f.seek(offset)
                    chunk = f.read()
                    offset = f.tell()
                buffered += chunk.decode(errors='replace')
                while '\n' in buffered:
                    line, buffered = buffered.split('\n', 1)
                    if line.strip():
                        self.notify_status(line)
            state = await self.service_status()
            if state.get('ActiveState') not in ('active', 'activating', 'deactivating', 'reloading'):
                # tee may still be draining the final lines when the service exits.
                await asyncio.sleep(0.2)
                if LOG.exists():
                    with LOG.open('rb') as f:
                        f.seek(offset)
                        buffered += f.read().decode(errors='replace')
                for line in buffered.splitlines():
                    if line.strip():
                        self.notify_status(line)
                if state.get('Result') != 'success' or state.get('ExecMainStatus') != '0':
                    raise self.server.error('Firmware service failed: ' + str(state))
                return
            now = time.monotonic()
            if now - heartbeat > 20:
                self.notify_status('Firmware rebuild is still running (%d seconds). Detailed log: logs/rebuild-firmware.log' % (now - started))
                heartbeat = now
            if now - started > 1200:
                raise self.server.error('Firmware rebuild exceeded 20 minutes; service remains running. Check rebuild-firmware.log')
            await asyncio.sleep(0.5)

    async def reconnect(self, host, expected):
        deadline = time.monotonic() + 120
        detail = 'Klipper has not reconnected'
        while time.monotonic() < deadline:
            try:
                current_host, versions = await self.snapshot()
                if current_host != host:
                    raise self.server.error('Klipper changed during the firmware update')
                if all(versions.get(n) == host for n in expected):
                    self.host, self.mcus = current_host, versions
                    self.problem = ''
                    return
                detail = 'Firmware still differs: ' + ', '.join(n + ': ' + versions.get(n, 'missing') for n in expected if versions.get(n) != host)
            except Exception as e:
                detail = str(e)
            await asyncio.sleep(1)
        raise self.server.error('Klipper/MCU verification timed out: ' + detail)

    async def update(self):
        if self.cmd_helper.is_full_update():
            self.notify_status('Skipping firmware: use its separate Update button when ready.')
            return False
        try:
            self.notify_status('Checking printer idle and running firmware versions...')
            await self.require_idle()
            host, mcus = await self.snapshot()
            state = await self.service_status()
            if state.get('ActiveState') in ('active', 'activating', 'deactivating'):
                raise self.server.error('A firmware rebuild is already running')
            self.notify_status('Building and flashing firmware for installed Klipper ' + host)
            self.notify_status('Before: ' + ', '.join(n + ': ' + v for n, v in mcus.items()))
            await self.run_service()
            self.notify_status('Waiting for Klipper and configured MCUs to reconnect and checking their firmware versions...')
            await self.reconnect(host, mcus)
            self.notify_status('SUCCESS: all configured MCUs are ready and running firmware ' + host)
            self.notify_status('Firmware update complete. Detailed log: logs/rebuild-firmware.log', is_complete=True)
            asyncio.get_running_loop().call_later(0.2, self.cmd_helper.notify_update_refreshed)
            return True
        except Exception as e:
            self.notify_status('FAILED: ' + str(e))
            raise


class KlipperFirmware:
    def __init__(self, config):
        self.server = config.get_server()
        self.manager = self.server.load_component(config, 'update_manager')
        self.updater = FirmwareUpdater(config)
        self.manager.updaters[NAME] = self.updater
        self.server.register_event_handler('server:klippy_ready', self.on_ready)

    async def on_ready(self):
        await self.updater.refresh()
        self.manager.cmd_helper.notify_update_refreshed()


def load_component(config):
    return KlipperFirmware(config)
