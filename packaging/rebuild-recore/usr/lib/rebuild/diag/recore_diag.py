"""Standalone command-line front end for the Recore-CI stress worker."""
import argparse
import base64
import fcntl
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid

from stress_log import format_record

REPORTS = Path('/var/lib/recore-diag')
HERE = Path(__file__).resolve().parent


def compact_sample(record):
    def clock(seconds):
        value = max(0, int(round(seconds or 0)))
        return f'{value // 60}:{value % 60:02d}'
    def mhz(value, scale):
        return f'{float(value) / scale:g}' if value is not None else '?'
    parts = ['time:' + clock(record.get('elapsed_seconds')) + '/' + clock(record.get('remaining_seconds'))]
    for name, value in record.get('temperatures_c', {}).items():
        label = name.lower().replace('-thermal', '')
        parts.append(f'{label}:{value:.1f}C')
    if not record.get('temperatures_c'):
        parts.append('temp:?')
    parts.extend(['cpu:' + mhz(record.get('cpu_khz'), 1000) + 'MHz',
                  'gpu:' + mhz(record.get('gpu_hz'), 1000000) + 'MHz'])
    fps = record.get('gpu_fps')
    if record.get('config', {}).get('gpu') or 'gpu' in record.get('loads', {}):
        parts.append('fps:' + (f'{fps:g}' if fps is not None else '?'))
    if 'memory' in record.get('loads', {}):
        parts.append(f"mem:{record.get('memory_loops_completed', 0)}p/{record.get('memory_failures', 0)}e")
    return ' '.join(parts)


def options(argv=None):
    p = argparse.ArgumentParser(description='Recore diagnostics; stress is opt-in. Review logs before sharing.')
    p.add_argument('--stress', action='store_true', help='run selected loads; installs missing tools')
    p.add_argument('--minutes', type=float, default=20)
    p.add_argument('--interval', type=int, default=5, help='status interval in seconds (2..30)')
    p.add_argument('--verbose', action='store_true', help='detailed periodic status, including load states')
    for name in ('cpu', 'gpu', 'memory', 'last'):
        p.add_argument('--' + name, action='store_true')
    p.add_argument('--memory-mb', type=int, default=128)
    p.add_argument('--cpu-workers', type=int, default=min(4, os.cpu_count() or 1))
    p.add_argument('--gpu-mode', choices=('onscreen', 'offscreen'), default='offscreen')
    p.add_argument('--thermal-limit', type=int, default=88)
    a = p.parse_args(argv)
    if not math.isfinite(a.minutes) or not 10 <= a.minutes * 60 <= 3600:
        p.error('--minutes must give a duration between 10 seconds and 60 minutes')
    if not 2 <= a.interval <= 30:
        p.error('--interval must be 2..30 seconds')
    if not 16 <= a.memory_mb <= 4096 or not 1 <= a.cpu_workers <= (os.cpu_count() or 1):
        p.error('invalid memory size or CPU worker count')
    if not 50 <= a.thermal_limit <= 90:
        p.error('--thermal-limit must be 50..90 C')
    if any((a.cpu, a.gpu, a.memory)) and not a.stress:
        p.error('load options require --stress')
    if a.stress and not any((a.cpu, a.gpu, a.memory)):
        p.error('select --cpu, --gpu and/or --memory')
    if a.last and a.stress:
        p.error('--last cannot be combined with --stress')
    return a


def configuration(a):
    return dict(duration_seconds=int(a.minutes * 60), sample_seconds=a.interval,
                cpu=a.cpu, gpu=a.gpu, memory=a.memory, memory_mb=a.memory_mb,
                cpu_workers=a.cpu_workers, memory_loops=1, gpu_mode=a.gpu_mode,
                thermal_limit_c=a.thermal_limit, install_tools=True)


def snapshot(say):
    # Do not dump configuration files, API credentials or command-line secrets.
    for name, command in (
        ('Board revision', ['get-recore-revision']),
        ('Board serial', ['get-serial-number']),
        ('Kernel', ['uname', '-r']),
        ('Uptime', ['uptime', '-p']),
        ('Storage', ['df', '-h', '/', '/boot']),
        ('Memory', ['free', '-m']),
        ('Klipper/Moonraker', ['systemctl', 'is-active', 'klipper', 'moonraker']),
    ):
        try:
            r = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=8)
            say(name + ': ' + (r.stdout.strip() or 'unavailable'))
        except (OSError, subprocess.TimeoutExpired):
            say(name + ': unavailable')
    for path in ('/etc/rebuild-version', '/proc/device-tree/model'):
        try:
            say(path + ': ' + Path(path).read_text().strip().rstrip('\0'))
        except OSError:
            say(path + ': unavailable')


def main(argv=None):
    a = options(argv)
    if os.geteuid() != 0:
        print('Run with sudo.', file=sys.stderr)
        return 2
    if a.last:
        files = sorted(REPORTS.glob('*/report.txt'))
        if not files:
            print('No saved report.')
            return 1
        print(files[-1].read_text(), end='')
        return 0
    REPORTS.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(REPORTS, 0o700)
    run = REPORTS / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:6])
    run.mkdir(mode=0o700)
    with (run / 'report.txt').open('w') as report:
        def say(line):
            text = '[' + datetime.now().strftime('%H:%M:%S') + '] ' + line
            print(text, flush=True)
            report.write(text + '\n')
            report.flush()
            os.fsync(report.fileno())
        say('RECORE DIAG | report: ' + str(run / 'report.txt'))
        say('Review the report before sharing. No automatic uploads; no clock/voltage changes.')
        snapshot(say)
        if not a.stress:
            say('INFO: report-only mode; no loads started or packages installed.')
            return 0
        lock = open('/run/recore-diag.lock', 'w')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say('RESULT: ERROR — another recore-diag stress run is active')
            lock.close()
            return 1
        say('Stress is opt-in; required missing packages will be installed. Do not start a print during this test.')
        config = configuration(a)
        encoded = base64.b64encode(json.dumps(config).encode()).decode()
        unit = 'recore-diag-' + uuid.uuid4().hex[:12]
        command = ['systemd-run', '--quiet', '--wait', '--pipe', '--collect',
                   '--unit=' + unit, '--property=KillMode=control-group',
                   '--property=RuntimeMaxSec=' + str(config['duration_seconds'] + 180),
                   sys.executable, '-u', str(HERE / 'stress-workload.py'), '--config', encoded]
        proc = None
        result = None
        def cancel(signum, frame):
            raise InterruptedError('operator cancellation')
        previous = {s: signal.signal(s, cancel) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            with (run / 'raw.log').open('w') as raw:
                proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in proc.stdout:
                    raw.write(line)
                    raw.flush()
                    if line.startswith(('SETTINGS ', 'TELEMETRY ', 'RESULT ')):
                        os.fsync(raw.fileno())
                        kind, payload = line.split(' ', 1)
                        record = json.loads(payload)
                        say(compact_sample(record) if kind == 'TELEMETRY' and not a.verbose else format_record(kind, record))
                        if kind == 'RESULT':
                            result = record
                    elif line.startswith(('SETUP ', 'WARNING ', 'ERROR ')):
                        say(line.rstrip())
                rc = proc.wait(timeout=10)
                if result is None:
                    say('RESULT: ERROR — worker ended without a final result; inspect raw.log')
                    return 1
                return 0 if rc == 0 and result['status'] == 'passed' else 1
        except InterruptedError:
            say('RESULT: CANCELLED — operator interruption; stopping selected loads')
            return 130
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            say('RESULT: ERROR — ' + str(exc))
            return 1
        finally:
            for s in previous:
                signal.signal(s, signal.SIG_IGN)
            if proc is not None:
                subprocess.run(['systemctl', 'stop', unit], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=15, check=False)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=5)
            say('Saved report: ' + str(run / 'report.txt') + ' | full tool output: ' + str(run / 'raw.log'))
            for s, handler in previous.items():
                signal.signal(s, handler)
            lock.close()


if __name__ == '__main__':
    raise SystemExit(main())
