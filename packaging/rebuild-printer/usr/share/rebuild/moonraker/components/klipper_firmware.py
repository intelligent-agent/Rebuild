"""Build and flash Klipper MCU firmware through Moonraker update clients."""
import asyncio
import hashlib
import importlib.util
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
# The user's override files, and what rebuild-firmware records of what it
# flashed (#159). The digest is computed by its helper, so there is one
# definition of "the config changed".
USERDIR = pathlib.Path('/home/printer/printer_data/config/firmware')
RECORDS = pathlib.Path('/opt/firmware')
HELPER = pathlib.Path('/usr/lib/rebuild/firmware-kconfig.py')


def revision(value):
    value = re.sub(r'-\d{8}_\d{6}-[A-Za-z0-9][A-Za-z0-9.-]*$', '', value)
    return value.removesuffix('-dirty')


def role_of(chip):
    """The rebuild-firmware role an MCU chip is built under, if any."""
    if chip == 'ar100':
        return 'ar100'
    if chip.startswith('stm32'):
        return 'stm32'
    if chip == 'rp2040':
        return 'rp2040'
    return None


_helper = {}


def user_digest(path):
    # Loaded once per helper file, and again if the package is upgraded.
    key = (str(HELPER), HELPER.stat().st_mtime_ns)
    if key not in _helper:
        spec = importlib.util.spec_from_file_location('firmware_kconfig', HELPER)
        _helper[key] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_helper[key])
    return _helper[key].digest(str(path))


def fingerprint(versions):
    return hashlib.sha256(json.dumps(versions, sort_keys=True).encode()).hexdigest()


class FirmwareUpdater(BaseDeploy):
    roles = frozenset()

    def __init__(self, config):
        super().__init__(config, name=NAME)
        self.host = ''
        self.mcus = {}
        self.roles = set()
        self.problem = ''

    def config_state(self):
        """{role: (applied, current)} for the roles on this board.

        applied is what the flashed firmware was built from; no record means
        the stock firmware the image shipped with.
        """
        state = {}
        for role in sorted(self.roles):
            try:
                applied = (RECORDS / (role + '.applied')).read_text().strip() or 'stock'
            except OSError:
                applied = 'stock'
            state[role] = (applied, user_digest(USERDIR / (role + '.config')))
        return state

    def changed_roles(self):
        return [r for r, (applied, current) in self.config_state().items() if applied != current]

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
        self.roles = {r for r in (role_of(status[n].get('mcu_constants', {}).get('MCU', '')) for n in names) if r}
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

    def pending(self):
        """What the Update button would do: (reasons, remote_version)."""
        reasons = []
        stale = sorted(n for n, v in self.mcus.items() if v != self.host)
        if stale:
            reasons.append((
                'Firmware built from another Klipper revision',
                ', '.join(n + ': ' + self.mcus[n] for n in stale) + '; installed Klipper is ' + self.host))
        for role in self.changed_roles():
            reasons.append((
                role + '.config has changed since the firmware was flashed',
                'config/firmware/' + role + '.config differs from what the ' + role + ' MCU runs. Reverting it to match also counts as a change.'))
        return reasons

    def get_update_status(self):
        state = self.config_state()
        actual = fingerprint(dict(self.mcus, **{'config ' + r: a for r, (a, _) in state.items()}))
        wanted = fingerprint(dict({n: self.host for n in self.mcus}, **{'config ' + r: c for r, (_, c) in state.items()}))
        warnings = [self.problem] if self.problem else []
        reasons = self.pending() if self.mcus else []
        if reasons:
            warnings.append('Firmware needs an update: ' + '; '.join(r for r, _ in reasons)
                            + '. Use this Update button to rebuild and flash. Update all leaves firmware unchanged.')
        summary = ', '.join(n + ': ' + v for n, v in self.mcus.items()) or 'MCU versions unavailable'
        changed = [r + '.config' for r in self.changed_roles()]
        remote = self.host + (' with ' + ', '.join(changed) if changed else '')
        # Mainsail marks an entry updatable from commits_behind (or semver),
        # not from the hashes Fluidd compares, so describe what is pending as
        # commits. They are not Git commits: nothing is fetched or applied.
        now = int(time.time())
        commits = [dict(sha=hashlib.sha1(subject.encode()).hexdigest(), author='Rebuild',
                        date=now, subject=subject, message=message, tag=None)
                   for subject, message in reasons]
        return dict(
            configured_type='git_repo', detected_type='git_repo',
            is_valid=True, is_dirty=False, pristine=True, corrupt=False,
            version=summary, remote_version=remote, full_version_string=summary,
            current_hash=actual, remote_hash=wanted,
            remote_url='?', branch='installed Klipper', channel='dev',
            commits_behind=commits, commits_behind_count=len(commits), git_messages=[],
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
        # Klipper restarting, as it does right after a Klipper update, answers
        # with these objects present but empty. That is "cannot tell", not
        # "idle", and not a crash: it was a KeyError and a 500 on an a6.
        try:
            printing = status['print_stats']['state'] in ('printing', 'paused')
            active = status['virtual_sdcard']['is_active']
            moving = status['idle_timeout']['state'] == 'Printing'
        except (KeyError, TypeError):
            raise self.server.error('Firmware update refused: Klipper is not ready, so it cannot tell whether the printer is printing. Try again in a moment.')
        if printing or active or moving:
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

    def verify_config(self, requested):
        """Matching revision strings do not show the edited options are in:
        the build records what it flashed, and that must be what was asked
        for - or what the file is now, if it was saved again meanwhile."""
        unapplied = [role + '.config' for role, (applied, current) in self.config_state().items()
                     if applied not in (requested.get(role), current)]
        if unapplied:
            raise self.server.error('Firmware was not built from the current ' + ', '.join(unapplied)
                                    + '; see logs/rebuild-firmware.log')

    async def update(self):
        if self.cmd_helper.is_full_update():
            self.notify_status('Skipping firmware: use its separate Update button when ready.')
            return False
        try:
            self.notify_status('Checking printer idle and running firmware versions...')
            await self.require_idle()
            host, mcus = await self.snapshot()
            requested = {role: current for role, (_, current) in self.config_state().items()}
            state = await self.service_status()
            if state.get('ActiveState') in ('active', 'activating', 'deactivating'):
                raise self.server.error('A firmware rebuild is already running')
            self.notify_status('Building and flashing firmware for installed Klipper ' + host)
            self.notify_status('Before: ' + ', '.join(n + ': ' + v for n, v in mcus.items()))
            for role in self.changed_roles():
                self.notify_status('Including your changes in config/firmware/' + role + '.config')
            await self.run_service()
            self.notify_status('Waiting for Klipper and configured MCUs to reconnect and checking their firmware versions...')
            await self.reconnect(host, mcus)
            self.verify_config(requested)
            self.notify_status('SUCCESS: all configured MCUs are ready and running firmware ' + host
                               + ' with the current config/firmware settings')
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
        self.server.register_event_handler('file_manager:filelist_changed', self.on_files)
        self.notify = None

    def on_files(self, event):
        """A firmware override was saved, deleted or restored: tell open
        clients to ask again. The status itself is computed on every request."""
        item = event.get('item', {})
        if item.get('root') != 'config' or not item.get('path', '').startswith('firmware/'):
            return
        # An editor saves in several steps; one notice covers them.
        if self.notify is not None:
            self.notify.cancel()
        loop = asyncio.get_running_loop()
        self.notify = loop.call_later(1.0, self.manager.cmd_helper.notify_update_refreshed)

    async def on_ready(self):
        await self.updater.refresh()
        self.manager.cmd_helper.notify_update_refreshed()


def load_component(config):
    return KlipperFirmware(config)
