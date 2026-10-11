"""Offline restore integration tests using real installed Moonraker code.

MOONRAKER_TEST_SOURCE=/path/to/moonraker
MOONRAKER_TEST_PYTHON=/path/to/moonraker-env/bin/python
python3 -m unittest discover -s packaging/tests -p test_moonraker_database.py
"""
import hashlib
from contextlib import contextmanager, closing
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import shutil
import tarfile
import socket
import time
import urllib.error
import urllib.request
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'rebuild-printer/usr/lib/rebuild/migrate-moonraker-database'
loader = importlib.machinery.SourceFileLoader('database_restore', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
restore = importlib.util.module_from_spec(spec)
loader.exec_module(restore)
SOURCE = os.environ.get('MOONRAKER_TEST_SOURCE')
PYTHON = os.environ.get('MOONRAKER_TEST_PYTHON')


@contextmanager
def database(path):
    with closing(sqlite3.connect(path)) as connection:
        with connection:
            yield connection


def legacy_fixture(directory, broken=False):
    directory.mkdir()
    path = directory / restore.DB_NAME
    with database(path) as conn:
        conn.executescript('''CREATE TABLE namespace_store (
            namespace TEXT NOT NULL, key TEXT NOT NULL, value record NOT NULL,
            PRIMARY KEY(namespace,key));
            CREATE TABLE table_registry (name TEXT PRIMARY KEY NOT NULL, prototype TEXT NOT NULL, version INT);''')
        account = {'username': 'example', 'password': 'synthetic-hash', 'salt': 'synthetic-salt',
                   'jwt_secret': '00' * 32, 'jwk_id': 'synthetic-key', 'groups': ['admin']}
        if broken:
            del account['password']
        for namespace, key, value in [
            ('authorized_users', 'example', account),
            ('authorized_users', '_API_KEY_USER_', {'api_key': 'synthetic-api-key'}),
            ('fluidd', 'preferences', {'layout': 'compact'}),
            ('mainsail', 'preferences', {'theme': 'dark'}),
            ('webcams', 'camera', {'name': 'example', 'urlStream': '/webcam/?action=stream'}),
            ('history', 'old-job', {'filename': 'old.gcode'}),
            ('moonraker', 'history', {'job_totals': {'total_jobs': 100}}),
            ('gcode_metadata', 'old.gcode', {'size': 123}),
            ('announcements', 'old-announcement', {}),
            ('update_manager', 'klipper', {'version': 'old-version'}),
        ]:
            conn.execute('INSERT INTO namespace_store VALUES(?,?,?)',
                         (namespace, key, json.dumps(value).encode()))
    return path


@unittest.skipUnless(SOURCE and PYTHON, 'set Moonraker source and Python environment for real integration tests')
class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        printer = self.root / 'home/printer'
        printer.mkdir(parents=True)
        (printer / 'moonraker').symlink_to(SOURCE, target_is_directory=True)
        (printer / 'moonraker-env').symlink_to(Path(PYTHON).parent.parent, target_is_directory=True)
        self.target = printer / 'printer_data/database'
        self.target.parent.mkdir()
        self.source = self.root / 'archive'

    def run_restore(self):
        return subprocess.run([str(HELPER), '--root', str(self.root), '--source', str(self.source),
                               '--target', str(self.target)], capture_output=True, text=True, timeout=30)

    def assert_fresh(self):
        with database(self.target / restore.DB_NAME) as conn:
            self.assertEqual(conn.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(conn.execute('SELECT count(*) FROM job_history').fetchone()[0], 0)
            self.assertEqual(conn.execute('SELECT count(*) FROM job_totals WHERE coalesce(total,0) != 0 OR coalesce(maximum,0) != 0').fetchone()[0], 0)
            namespaces = {row[0] for row in conn.execute('SELECT DISTINCT namespace FROM namespace_store')}
            self.assertTrue(namespaces.issubset(set(restore.KEEP)))
            self.assertEqual(conn.execute('SELECT count(*) FROM authorized_users').fetchone()[0], 1)

    def test_preserves_preferences_cameras_and_auth_discards_history_caches(self):
        path = legacy_fixture(self.source)
        digest = hashlib.sha256(path.read_bytes()).digest()
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('accounts kept', result.stderr)
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), digest)
        with database(self.target / restore.DB_NAME) as conn:
            self.assertEqual({row[0] for row in conn.execute('SELECT DISTINCT namespace FROM namespace_store')}, set(restore.KEEP))
            self.assertEqual(conn.execute('SELECT count(*) FROM job_history').fetchone()[0], 0)
            self.assertEqual(conn.execute('SELECT count(*) FROM job_totals WHERE coalesce(total,0) != 0 OR coalesce(maximum,0) != 0').fetchone()[0], 0)
            self.assertEqual(conn.execute("SELECT password,salt,jwt_secret,jwk_id FROM authorized_users WHERE username='example'").fetchone(),
                             ('synthetic-hash', 'synthetic-salt', '00' * 32, 'synthetic-key'))
            self.assertEqual(conn.execute("SELECT password FROM authorized_users WHERE username='_API_KEY_USER_'").fetchone()[0], 'synthetic-api-key')
        recovered = list(self.target.parent.glob('database-restore-recovery/restore-*/archive/' + restore.DB_NAME))
        self.assertEqual(hashlib.sha256(recovered[0].read_bytes()).digest(), digest)
        # The second restore reads a modern SQL account table and must keep it.
        second = self.root / 'modern'
        shutil.copytree(self.target, second)
        self.source = second
        self.assertEqual(self.run_restore().returncode, 0)
        with database(self.target / restore.DB_NAME) as conn:
            self.assertEqual(conn.execute("SELECT password FROM authorized_users WHERE username='example'").fetchone()[0], 'synthetic-hash')

    def test_real_account_migration_failure_falls_back(self):
        legacy_fixture(self.source, broken=True)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('migration failed (TypeError)', result.stderr)
        self.assertIn('accounts reset', result.stderr)
        self.assertNotIn('synthetic-secret', result.stderr)
        self.assert_fresh()

    def test_corrupt_database_falls_back(self):
        self.source.mkdir()
        (self.source / restore.DB_NAME).write_bytes(b'not a database')
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('accounts reset', result.stderr)
        self.assert_fresh()

    def test_non_moonraker_sqlite_falls_back(self):
        self.source.mkdir()
        with database(self.source / restore.DB_NAME) as conn:
            conn.execute('CREATE TABLE unrelated(x)')
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('accounts reset', result.stderr)
        self.assert_fresh()

    def test_newer_account_schema_falls_back(self):
        self.test_preserves_preferences_cameras_and_auth_discards_history_caches()
        with database(self.source / restore.DB_NAME) as conn:
            conn.execute("UPDATE table_registry SET version=999 WHERE name='authorized_users'")
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('accounts reset', result.stderr)
        self.assert_fresh()

    def test_environment_failure_keeps_previous_database(self):
        legacy_fixture(self.source)
        self.target.mkdir()
        previous = self.target / restore.DB_NAME
        previous.write_bytes(b'previous untouched')
        (self.root / 'home/printer/moonraker').unlink()
        (self.root / 'home/printer/moonraker').mkdir()
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('accounts reset', result.stderr)
        self.assertEqual(previous.read_bytes(), b'previous untouched')

    def test_wal_commits_are_included(self):
        path = legacy_fixture(self.source)
        with database(path) as conn:
            conn.execute('PRAGMA journal_mode=WAL')
            conn.execute('PRAGMA wal_autocheckpoint=0')
            conn.execute('INSERT INTO namespace_store VALUES(?,?,?)', ('fluidd', 'wal-only', b'{"kept":true}'))
            conn.commit()
            result = self.run_restore()
            self.assertEqual(result.returncode, 0, result.stderr)
            with database(self.target / restore.DB_NAME) as result_db:
                self.assertIsNotNone(result_db.execute("SELECT value FROM namespace_store WHERE key='wal-only'").fetchone())

    def test_target_installer_restore_success_and_fallback(self):
        # This is the same entry point Reflash invokes in the target chroot.
        packaged = HELPER.parents[4] / 'rebuild-recore/usr/lib/reflash/target-installer'
        installed_helper = self.root / 'usr/lib/rebuild/migrate-moonraker-database'
        installed_helper.parent.mkdir(parents=True)
        shutil.copy2(HELPER, installed_helper)
        config = self.target.parent / 'config'
        config.mkdir()
        env = dict(os.environ, REFLASH_INTERFACE='1', REFLASH_TEST_ROOT=str(self.root))
        for broken in (False, True):
            with self.subTest(broken=broken):
                if self.source.exists():
                    shutil.rmtree(self.source)
                legacy_fixture(self.source, broken)
                archive = self.root / 'config-archive.tgz'
                saved_config = self.root / 'printer.cfg'
                saved_config.write_text('synthetic restored printer configuration\n')
                with tarfile.open(archive, 'w:gz') as tar:
                    tar.add(self.source, arcname='home/printer/printer_data/database')
                    tar.add(saved_config, arcname='home/printer/printer_data/config/printer.cfg')
                with archive.open('rb') as stdin:
                    result = subprocess.run([str(packaged), 'restore'], stdin=stdin,
                                            env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((config / 'printer.cfg').read_text(), saved_config.read_text())
                if broken:
                    self.assertIn('accounts reset', result.stderr)
                    self.assert_fresh()
                else:
                    self.assertIn('accounts kept', result.stderr)

    def test_archive_without_database_preserves_current_database(self):
        legacy_fixture(self.source)
        self.assertEqual(self.run_restore().returncode, 0)
        before = (self.target / restore.DB_NAME).read_bytes()
        installed_helper = self.root / 'usr/lib/rebuild/migrate-moonraker-database'
        installed_helper.parent.mkdir(parents=True)
        shutil.copy2(HELPER, installed_helper)
        manifest = self.root / 'rebuild-backup.manifest'
        manifest.write_text('format=1\n')
        archive = self.root / 'empty-archive.tgz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(manifest, arcname=manifest.name)
        packaged = HELPER.parents[4] / 'rebuild-recore/usr/lib/reflash/target-installer'
        with archive.open('rb') as stdin:
            result = subprocess.run([str(packaged), 'restore'], stdin=stdin,
                                    env=dict(os.environ, REFLASH_INTERFACE='1', REFLASH_TEST_ROOT=str(self.root)),
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / restore.DB_NAME).read_bytes(), before)

    @unittest.skipUnless(os.environ.get('MOONRAKER_TEST_FULL_SERVER'), 'optional full server test needs all Moonraker dependencies')
    def test_full_server_loads_migrated_and_fallback_database(self):
        for broken in (False, True):
            with self.subTest(broken=broken):
                if self.source.exists():
                    shutil.rmtree(self.source)
                legacy_fixture(self.source, broken)
                result = self.run_restore()
                self.assertEqual(result.returncode, 0, result.stderr)
                with socket.socket() as reservation:
                    reservation.bind(('127.0.0.1', 0))
                    port = reservation.getsockname()[1]
                config = self.root / 'isolated-moonraker.conf'
                config.write_text('[server]\nhost: 127.0.0.1\nport: ' + str(port)
                                  + '\nklippy_uds_address: ' + str(self.root / 'no-klipper.sock')
                                  + '\n[authorization]\ntrusted_clients: 127.0.0.1\n[machine]\nprovider: none\n')
                output = self.root / 'isolated-moonraker-output.log'
                with output.open('w') as log:
                    process = subprocess.Popen([PYTHON, '-B', str(Path(SOURCE) / 'moonraker/moonraker.py'),
                                                '-d', str(self.target.parent), '-c', str(config), '-n'],
                                               stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 30
                        info = None
                        while time.monotonic() < deadline and process.poll() is None:
                            try:
                                with urllib.request.urlopen(f'http://127.0.0.1:{port}/server/info', timeout=1) as response:
                                    info = json.load(response)['result']
                                if info['components'] and 'database' in info['components']:
                                    break
                            except (OSError, urllib.error.URLError):
                                pass
                            time.sleep(.2)
                        self.assertIsNotNone(info, output.read_text()[-2500:])
                        self.assertEqual(info['failed_components'], [], output.read_text()[-2500:])
                        self.assertIn('authorization', info['components'])
                        self.assertIn('history', info['components'])
                        self.assertIn('webcam', info['components'])
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/server/webcams/list', timeout=2) as response:
                            cameras = json.load(response)['result']['webcams']
                        if broken:
                            self.assertEqual(cameras, [])
                        else:
                            self.assertEqual(len(cameras), 1)
                            self.assertEqual(cameras[0]['stream_url'], '/webcam/?action=stream')
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()


class FailureTests(unittest.TestCase):
    def test_failed_fresh_initialization_never_replaces_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            (source / restore.DB_NAME).write_bytes(b'bad')
            target = root / 'database'
            target.mkdir()
            (target / restore.DB_NAME).write_bytes(b'keep')
            (root / 'home/printer/moonraker-env/bin').mkdir(parents=True)
            (root / 'home/printer/moonraker-env/bin/python').touch()
            (root / 'home/printer/moonraker').mkdir()
            with patch.object(restore.subprocess, 'run', return_value=type('Result', (), {'returncode': 1})()):
                with self.assertRaisesRegex(RuntimeError, 'fresh database'):
                    restore.restore(source, target, root)
            self.assertEqual((target / restore.DB_NAME).read_bytes(), b'keep')

    def test_failed_candidate_sidecars_do_not_survive_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            legacy_fixture(source)
            target = root / 'database'
            (root / 'home/printer/moonraker-env/bin').mkdir(parents=True)
            (root / 'home/printer/moonraker-env/bin/python').touch()
            (root / 'home/printer/moonraker').mkdir()

            def simulated_worker(command, **kwargs):
                destination = Path(command[command.index('--worker') + 1])
                if '--source' in command:
                    destination.write_bytes(b'failed candidate')
                    Path(str(destination) + '-wal').write_bytes(b'stale WAL')
                    Path(str(destination) + '-journal').write_bytes(b'stale journal')
                    return type('Result', (), {'returncode': restore.BAD_DATABASE})()
                destination.write_bytes(b'validated fresh database')
                return type('Result', (), {'returncode': 0})()

            with patch.object(restore.subprocess, 'run', side_effect=simulated_worker):
                restore.restore(source, target, root)
            self.assertEqual((target / restore.DB_NAME).read_bytes(), b'validated fresh database')
            self.assertEqual({p.name for p in target.iterdir()}, {restore.DB_NAME})

    def test_unexpected_runner_failure_does_not_reset_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            legacy_fixture(source)
            target = root / 'database'
            target.mkdir()
            (target / restore.DB_NAME).write_bytes(b'keep')
            (root / 'home/printer/moonraker-env/bin').mkdir(parents=True)
            (root / 'home/printer/moonraker-env/bin/python').touch()
            (root / 'home/printer/moonraker').mkdir()

            def simulated_worker(command, **kwargs):
                destination = Path(command[command.index('--worker') + 1])
                destination.write_bytes(b'fresh')
                return type('Result', (), {'returncode': 1 if '--source' in command else 0})()

            with patch.object(restore.subprocess, 'run', side_effect=simulated_worker):
                with self.assertRaisesRegex(RuntimeError, 'runner failed'):
                    restore.restore(source, target, root)
            self.assertEqual((target / restore.DB_NAME).read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
