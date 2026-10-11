# Recore input voltage

Rebuild packages a `recore_sensors` Moonraker component that bridges Recore's
existing Klipper ADC reading into Moonraker's generic sensor API. Fluidd displays
**Input voltage** in its Sensors card, including a voltage graph. Mainsail displays
it in its Miscellaneous panel. Both receive units of **V**; no frontend fork,
MQTT broker or firmware changes are required.

`moonraker-extras` links the packaged module into the Moonraker checkout and adds:

```ini
[recore_sensors]
type: Recore
name: Input voltage
parameter_voltage: units=V
```

It restores missing links on subsequent starts after checkout updates, and adds
missing configuration after archive restores. Existing sections and user modules
are preserved. An optional `klipper_object` setting selects a custom ADC object.
By default the component prefers `temperature_sensor _voltage` and falls back to
`temperature_sensor voltage` for restored older configurations. The A5–A8 config
templates now use `_voltage` to keep the ADC out of temperature cards. Older
restored configs still show their legacy temperature entry until it is renamed.

The bridge uses Moonraker's sensor sampling/history timer (one second) and
Klipper's existing ADC updates. This is a dashboard measurement, not the fast
power-loss detector. Disconnect/shutdown clears readings and graph samples;
reconnection subscribes again. Missing sensors remain unavailable rather than
producing a fabricated zero. Klipper can itself report zero briefly before its
first ADC sample following startup.

Compatibility: the component uses Moonraker's `BaseSensor` and sensor registry.
Fluidd consumes `parameter_info`; Mainsail v2.19 consumes matching unit metadata
published in `/server/config`. That synthetic configuration metadata stays in
memory and does not introduce an unsupported `[sensor ...]` section on disk.
CI exercises these interfaces against the image's pinned Moonraker and the
updated revision used in validation.

Validation on Bad-A8 (2026-10-11): the old ADC object and new hidden object both
reported approximately 20.6 V. The real sensor endpoints supplied units and graph
samples without warnings. Stopping Klipper cleared readings and history;
restarting restored voltage and left Klipper ready/idle. Frontend placement and
unit handling were checked in Fluidd v1.37.4 and Mainsail v2.19 source, without a
browser rendering test. The voltage-only demo remains installed on Bad-A8.
