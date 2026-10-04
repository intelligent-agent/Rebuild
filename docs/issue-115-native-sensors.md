# Native Klipper sensors prototype (#115)

This experimental image uses `intelligent-agent/moonraker`, branch
`feature/klipper-sensors`, commit `ce61013679c8126ae3910dc14963562271353443`.
The proposed upstream change extends Moonraker's existing `sensor` component
with `type: klipper`; there is no extra component copied into its source tree.
No kernel, GPU, display, or Klipper firmware changes are included.

Voltage/current sensor sections are written directly in the Fluidd and Mainsail
Moonraker config files. Their objects match the `_voltage` and `_current` names
in the shipped Recore A5-A8 Klipper config files. A7/A8 also rename the existing
fan reading to `_fan_current`. Only those Klipper section headings change;
ADC conversions, gcode IDs, min/max limits and shutdown alarms are unchanged.
The leading underscore hides the legacy temperature entries in Fluidd.

Commented Moonraker sections show how to enable fan/toolhead current when those
objects exist. Rename a toolhead's current sensor to `_remote_current` directly
in its own Klipper config if using that example. Toolhead hardware configs are
not shipped by Rebuild. No generator, generated include or startup hook exists.

Existing user-owned configs are not rewritten by an upgrade. To test this image
with a restored printer config (including Recore-CI provisioning), change the
electrical sensor headings directly to the matching underscore names and check
any macros referencing them. Voron's recovered demo already uses those names.
Fresh-image testing must verify this explicitly; provisioning that restores old
names will leave the new Moonraker sensors unavailable. Mainsail and KlipperScreen
rendering, and the shared config templates' OctoPrint behavior, remain to be
verified separately before any merge.

The prototype stays on an attached Git branch tracking the fork. Moonraker's
supported `pinned_commit` update-manager option keeps the prototype at its tested
commit during CI upgrades. Moonraker may report the unofficial origin/branch:
that is expected and is not concealed. Its built-in updater does not support
overriding its own origin/primary_branch through configuration. Hard recovery
may clone upstream and lose this experiment; do not use recovery as an upgrade
test. This image is not intended as the long-term fork/updater policy.

After upstream acceptance, use the upstream repository and a release/commit
containing the feature, remove the prototype updater pin, and retain the native
sensor configuration. No custom Moonraker module will need to be maintained.

Focused checks:

```
python3 packaging/tests/test_klipper_sensors.py
python3 tests/test_klipper_sensor.py  # in the Moonraker fork
```

Full image provisioning, API readings, Klipper reconnect, software upgrade and
frontend behavior should be verified by the visible Recore-CI run before merge.

On 2026-10-04, the native fork was also tested directly on idle Voron: all four
electrical readings were available, Moonraker reported no failed components or
configuration warnings, and readings/history resumed after restarting Klipper.
The updater reported a clean attached branch, `is_valid: true`, and matching
current/remote pinned commits. The expected unofficial-origin/branch anomalies
remained visible. This is a runtime check, not a completed fresh-image CI test.
