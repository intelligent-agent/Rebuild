# Native Klipper sensors prototype (#115)

This experimental image uses `intelligent-agent/moonraker`, branch
`feature/klipper-sensors`, commit `ce61013679c8126ae3910dc14963562271353443`.
The proposed upstream change extends Moonraker's existing `sensor` component
with `type: klipper`; there is no extra component copied into its source tree.
No kernel, GPU, display, or Klipper firmware changes are included.

Before Moonraker starts, `rebuild-klipper-sensors` reads `printer.cfg` and its
includes and generates `rebuild-sensors.conf`. Voltage/current/fan/toolhead
sensors are included only when configured. Both ordinary and underscore-prefixed
sensor names work. Existing ADC conversion, min/max limits and shutdown safety
remain entirely in Klipper and are not modified by this helper.

Fluidd displays these measurements in its Sensors card with V/A units. Existing
unprefixed Klipper names also remain visible as legacy temperature readings.
To hide those duplicates, rename the corresponding Klipper section to e.g.
`[temperature_sensor _voltage]`, updating any references to that object, then
restart Klipper and Moonraker. This is intentionally not an automatic migration
of user-owned printer configuration. Voron's recovered demo already uses hidden
names. Mainsail and KlipperScreen rendering remain to be verified separately.

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
