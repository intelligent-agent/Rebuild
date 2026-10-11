# Moonraker database restore

Reflash calls Rebuild's `target-installer restore` inside the mounted target
image. When the archive's database is selected, Rebuild runs
`/usr/lib/rebuild/migrate-moonraker-database` using the target Moonraker checkout
and virtual environment. Database files are restored as one unit, including
when a single database file is selected in Reflash. A config-only selection
does not change the database.

The helper uses Moonraker's SQL provider and account table migration routines
without starting its service, binding ports or connecting to Klipper. It
first verifies that the installed Moonraker can create a fresh database.
Then it takes a SQLite backup of the archive's working copy, including WAL
transactions, migrates accounts, and transfers these categories into a
fresh target-defined database:

- Fluidd and Mainsail preferences.
- UI-managed webcam definitions.
- Accounts, password hashes, API keys and authentication secrets.

History, totals, G-code metadata, announcements, update-manager state and
other internal namespaces are discarded. Fresh history totals start at zero.
The result is reopened and decoded through the installed provider before
being committed. This validates database initialization, not the complete
Moonraker service configuration or a Klipper connection.

Invalid databases, failed data migrations, newer unsupported account schemas
and migration timeouts fall back to the validated fresh database with a
`WARNING:` message. Legacy LMDB-only archives also reset: this offline path
does not attempt Moonraker's network-dependent LMDB installation. Missing
dependencies, unexpected runner failures, or failed fresh initialization
abort the restore and leave the target database/config unchanged. A running
target Moonraker must be stopped before invoking the helper directly; the
Reflash chroot target is already offline. The helper never calls systemctl.

Original archive and previous target database directories are kept under
`printer_data/database-restore-recovery/restore-*`, outside the served config
directory. Recovery directories are root-only and contain authentication
data. They are not included in normal config backups. The validated directory
replaces the entire database directory so old WAL files cannot be replayed.

## Integration tests

Tests use synthetic records, including a valid SQLite database with a legacy
account missing its password. This passes SQLite integrity but fails the
actual Moonraker account migration. No real credentials are needed.

With a Moonraker checkout and a Python environment containing its database
and authorization module dependencies:

```sh
MOONRAKER_TEST_SOURCE=/path/to/moonraker \
MOONRAKER_TEST_PYTHON=/path/to/moonraker-env/bin/python \
python3 -m unittest discover -s packaging/tests -p test_moonraker_database.py -v
bats packaging/tests/target-installer.bats
```

The package workflow runs these integration tests against the image's pinned
Moonraker release and the updated revision verified on the hardware rig.
