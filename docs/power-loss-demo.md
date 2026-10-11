# Power-loss demo (#140)

This is an experimental detector and persistence benchmark, not automatic print
resume. Keep it out of release images and occupied printers. Bad-A8 (0498) is the
current test board; Voron is reserved for printing.

## Detector and shutdown

Build `power-loss-prototype/src/power_monitor.c` into the installed Klipper
revision's STM32 firmware and install the matching host extra. The detector uses
PA4 and signals PF1 (UC-INT-1, A64 PG3 / Linux GPIO 195). It arms on
`klippy:ready`, samples nominally every 100 us, and requires three consecutive low
samples by default. ADC contention and conversion time increase that interval.
The existing voltage sensor shares the ADC pin; the interrupt output is reserved.

`emergency_shutdown: True` dispatches Klipper's emergency shutdown asynchronously.
On this A8 demo, replace the static high-power enable with an output that disables
that domain on MCU shutdown:

```ini
[output_pin _power_loss_high_power]
pin: !ar100:PF5
value: 1
shutdown_value: 0

[power_monitor]
sensor_pin: PA4
int_pin: PF1
threshold: 19
required_samples: 3
emergency_shutdown: True
```

Remove `[static_digital_output 24V_enable]`; do not define both. A8's T3 offset is
PG8, not PG3 (#142). Do not drive PF5 from Linux while AR100 owns that pin.

The shutdown is requested through the host, so it does not guarantee load shedding
before host power fails. A direct hardware/MCU route remains a production design
requirement. The post-trip 1 ms interrupt heartbeat is a measurement aid and is
reinstalled after MCU shutdown; it should not become a production interrupt storm.

## State-save benchmark

`power-loss-prototype/power-loss-save` runs as root on the board. Before arming it
creates and preallocates a unique 4096-byte file, fsyncs that file and its directory,
and caches Moonraker's G-code position, virtual-SD offset, print status and toolhead
state. It refreshes that cache every 250 ms. It performs no HTTP request on the
power-loss path. Cached commanded position is not the exact physical position at
power loss and is not sufficient for safe print resume.

```sh
sudo python3 power-loss-save --file /var/lib/rebuild/power-loss-demo/RUN.state \
  --run-id RUN --udp 192.168.32.125:47123 --sync
sudo python3 power-loss-save --read --file /var/lib/rebuild/power-loss-demo/RUN.state
```

The first GPIO edge supplies a kernel monotonic timestamp. A worker writes one
fixed block containing a length, CRC32, run identity, boot identity, cached state,
trip timestamp and write-start timestamp, then fsyncs it. Optional `--sync` follows
with `os.sync()`. Existing evidence files cannot be overwritten.

Completion events go to UDP on the rig and the serial console. Only the rig's
`SAVE_OK` proves the fsync call returned; a timestamp written inside a file cannot
prove its own flush finished. The checksum and run ID must also be checked after
power restoration. An unwritten, torn or truncated block fails validation. No
completion event does not prove failure by itself: readback is decisive.

The A64 heartbeat runs every 2 ms over UDP; frequent heartbeats are omitted from
UART output to avoid a 115200-baud backlog. Kernel GPIO timestamps measure MCU
edges; UDP receipt measures delivery to the rig. Last observed edges and heartbeats
are lower bounds, not exact times of electrical death or rail measurements.

## Recovery and comparisons

Before testing, save the original config and STM32 binary locally on the board,
with SHA256 values. Build in a separate Klipper checkout. Use
`REBUILD_FIRMWARE_DIR` to flash a private directory, leaving `/opt/firmware`
unchanged. After tests, restore the original config and binary, remove the host
extra, reset Klipper, verify ready/idle, and restore the PSU voltage/current profile.

Bad-A8 uses N6700 channel 2 at 20.4 V / 2.25 A. Never change another channel or the
shared mains during these tests. Test controlled undervoltage with the board still
powered, a gradual ramp, then hard cutoff. Include dirty storage in a separate
scenario. Do not compare PSU output-off with unplugging without characterizing
its output discharge behavior. Both the power source and connected USB paths can
change the available hold-up interval.

Small STM32 flash records are a possible alternative when eMMC cannot flush in
time. Such a design must reserve an erased flash page outside the firmware image,
prepare it before arming, verify supply/programming limits, and read back a
checksummed record after reboot. No STM32 flash persistence is implemented here.

## Bad-A8 observations, 2026-10-11

The test used the existing Fluidd image 93, Klipper `461c4e37`, and a temporary
STM32 build from that exact checkout. Bad-A8 has no motors or heaters attached.
The board's original config and STM32 binary were restored after the tests.

| Scenario | State flush after GPIO trip | Record survived reboot | Last observed A64 activity after trip |
| --- | ---: | --- | ---: |
| Hard output cutoff, save only | No completion | No (invalid header) | 5.38 ms |
| Hard output cutoff, save then global sync | No completion | No (invalid header) | 4.93 ms |
| Requested 25 ms undervoltage warning, then cutoff; 1 MiB dirty data | 6.68 ms | Yes, matching run and CRC | 24.88 ms |
| Same warning/cut with an active virtual-SD wait-only job | 6.85 ms | Yes; active filename and byte offset 200 saved | 28.54 ms |

The requested warning interval is a controller delay, not a precisely measured
voltage waveform. In both warning/cut cases the global sync started after the
state flush but no `SYNC_OK` arrived. It cannot be called a successful global
flush. The last received MCU edges on immediate cutoff were about 4 ms after
trip. The A64 heartbeat period was 2 ms, and delivery can stop before CPU execution.

An initial controlled dip to 18.5 V, without cutting power, produced a valid
readback, a state-flush completion at 8.97 ms and a global-sync completion at
43.74 ms. That early run used the old single-sample detector and exposed the
startup/shutdown callback issues fixed in this branch; keep it separate from
repeatability claims for the revised detector.

The earlier Voron measurements (different PSU, 20 V threshold) showed longer
observed activity. This is not evidence that Bad-A8's intrinsic capacitance is
worse: output discharge behavior, starting voltage, load, detector threshold and
measurement method differ. No Voron changes were made for these new tests.

Machine-readable summaries, run identities and raw-trace SHA256 values are in
`power-loss-prototype/bad-a8-results-20261011.json`. Compressed raw traces are retained under
`power-loss-prototype/results/bad-a8-20261011/`, with live copies on the rig
under `/tmp/power-loss-140/`; recovered records remain in Bad-A8's
`/var/lib/rebuild/power-loss-demo/`. The targeted controller
`power-loss-prototype/bad-a8-scenario` runs on the rig alongside Recore-CI and
requires `RECORE_PASS`; it deliberately verifies board 0498 and changes only
N6700 channel 2. It supports `dip`, `ramp`, `cut`, and `warning-cut`, optional
`--sync`, `--dirty-mib 1`, and `--simulate-job` (only timed waits).

Five integrity tests reject unwritten, torn, truncated, oversized and malformed
records. The STM32 firmware compiled to roughly 24 KiB and was flashed with
verification. This remains a demo: there is no guarantee of exact physical
position, complete filesystem protection, or safe automatic resume.
