# Manual Klipper firmware updates

The demo image provides a **Klipper firmware** entry in stock Fluidd and
Mainsail's update manager. It compares the installed Klipper revision with
all configured MCU revisions. Update Klipper first, then use this entry's
individual Update button to build and flash. **Update all skips firmware**,
regardless of its position in the update list.

The Moonraker component is packaged in rebuild-printer and linked into the
Moonraker checkout before startup. Its local Git exclusion keeps the checkout
clean. The startup helper also enables the component in restored configs and
removes rebuild-firmware from Moonraker's service controls. Existing
[rebuild_firmware] Klipper config sections remain valid but no longer emit
a warning; firmware status belongs to the update manager.

The updater starts the fixed root-owned rebuild-firmware service, streams
its log to the usual update dialog, sends an elapsed-time message during
quiet builds, checks the service's exit status, and waits for Klipper to be
ready with every configured MCU on the captured target revision before
reporting success. Printing and paused printers are refused. A failed flash
can retry a cached binary when its running MCU revision remains stale.
There are no web service stop/restart controls for interrupting a flash.

The image keeps the existing application pins: Klipper starts at
461c4e3722c3a897fba1c6b3f0780a5315043842 (v0.13.0-786). This leaves a software
update for Recore-CI's existing validation flow; firmware is then a separate
manual step. No Recore-CI firmware automation is included in this branch.

Validation:

    python3 packaging/tests/test_klipper_firmware.py
    bats packaging/tests/moonraker-extras.bats packaging/tests/klipper-extras.bats

The adapter's tests exercise Update all exclusion, printer interlocks,
failed service handling, mixed MCU versions and reconnect verification. The
startup helper's tests cover config restoration, service control removal,
Git cleanliness and repairing links after checkout updates.
