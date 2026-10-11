# STM32 recovery-record proof of concept

This experiment checks the proposed A64 → STM32 RAM → STM32 flash → A64 durable
handoff. It is not automatic print resume and does not establish physical motion
accuracy. Bad-A8/0498 is the test board. Do not install this on an occupied printer
or add it to release images. Recore's AR100 generates steps; the STM32 does not.

## What is implemented

The host extra streams synthetic timestamped XYZE samples at 1 ms spacing,
in four-sample batches every 4 ms, approximately 20 ms ahead. Batching keeps
messages within Klipper's packet-size limit and the 250 kbaud UART budget. Wire
coordinates are signed 16-bit micrometres with deliberately bounded synthetic
values; RAM/flash coordinates are signed 32-bit. This is a transport fixture,
not a general coordinate format for a printer.

The STM32 keeps a 32-sample RAM queue, applies samples whose MCU clock has arrived,
and freezes the selected sample when its existing PA4 voltage detector trips.
It asserts PF1/UC-INT-1 and writes a 44-byte record locally before reporting the
trip to Klipper. No A64 reply or filesystem flush is needed on this save path.
The matching host extension requests asynchronous emergency shutdown after that
report. This uses the serial trip report; a direct GPIO-triggered AR100 stop is
not implemented here. Neither stop latency nor physical position is validated.

The flash record contains magic/version, experiment identity, sample sequence,
sample clock, trip clock, XYZE, CRC32, a completion marker and a consumed marker.
The completion marker is programmed last; consumed remains erased until explicit
acknowledgment. Programming follows STM32F0's half-word sequence in
[ST RM0091](https://www.st.com/resource/en/reference_manual/dm00031936.pdf).

Only STM32F031 with 32KB flash is supported. Address `0x08007c00` is the reserved
last 1KB page. `prepare-recovery-build` excludes it from the linker ROM and rejects
an oversized binary. On boot an intact pending record is preserved; consumed or
invalid pages are erased before peripheral configuration. Arming refuses a pending
record or non-erased page. Consuming requires an MCU restart before another save.

## Durable handoff

The A64 writes an experiment context before starting the stream. Optional
`FILENAME` includes a SHA256 of the G-code fixture. It is identified by the same
RUN number as the flash record. The sample sequence identifies synthetic recovery
state; it is **not** a real G-code byte offset or interrupted command.

Commands:

```text
RECOVERY_DEMO_START RUN=123 INTERVAL_MS=1 FILENAME=fixture.gcode
RECOVERY_DEMO_QUERY
RECOVERY_DEMO_HANDOFF
RECOVERY_DEMO_CONSUME
FIRMWARE_RESTART
```

QUERY never clears the record. HANDOFF checks its CRC, experiment context,
synthetic coordinate formula and optional file hash, then writes/fsyncs an atomic
JSON handoff and its directory. CONSUME refuses without a matching handoff and
programs only the consumed marker. Repeated boots before consumption retain the
record; a boot after consumption exposes no pending record.

Files are under `/home/printer/printer_data/recovery-demo/`. Print filename,
interpreter state, offsets, bed mesh, temperature targets and other real recovery
context would live on the A64 in a later version. Physical homing, collision-free
return paths, reheating and resuming extrusion are not implemented.

## Reproducing on the dedicated test board

Save original config and installed STM32 binary locally on the board first. Use
an isolated Klipper checkout at the installed revision and its STM32/32KB build
configuration. Run `power-loss-prototype/prepare-recovery-build CHECKOUT` as that
checkout's owner. Install the matching `klippy/extras/power_monitor.py`, detector
config and shutdown-safe high-power output described in `power-loss-demo.md`.
Flash via `REBUILD_FIRMWARE_DIR` pointing to a private directory, not `/opt/firmware`.

Run `python3 power-loss-prototype/recovery-scenario` on the rig. It checks serial
0498 and idle/motor interlocks, holds the N6700 lock, changes only channel 2,
and restores its voltage/output profile in a finally block. Add `--print-cut`
to cut during a real wait-only virtual-SD print with filename/hash context. Results go to
`/tmp/recovery-prototype-results/`. It exercises a controlled voltage dip, hard
cut and warning-then-cut, followed by restart retention, durable handoff and
consumption. The seed data is synthetic; the test never moves or heats anything.

After capturing results, restore the original config and STM32 binary, remove
the host extra and verify Klipper ready. A firmware flash may erase the recovery
page; copy successful evidence to the rig before restoring firmware.

## Bad-A8 results, 2026-10-11

| Scenario | STM32 record survived | Sample age at detection | Complete handoff/consume test |
| --- | --- | ---: | --- |
| Controlled dip to 18.5V | Yes | 0.064 ms | Passed |
| Immediate output cut | Yes | 0.996 ms | Passed |
| 30 ms requested warning, then cut | Yes | 0.877 ms | Passed |
| Hard cut during wait-only virtual-SD print, durable G-code | Yes | 0.596 ms | Passed |

Each completed case retained the record across another firmware restart, copied
it durably to the A64, consumed it and showed no pending record after restart.
No dropped batches were reported in pre-cut checks. Sample ages are MCU clock
differences relative to the detector event, not measurements of physical error or
remaining hold-up time. Warning duration is a requested PSU-controller delay,
not a characterized voltage waveform. The board has no motors/heaters attached.

An earlier print-cut captured a valid record (0.499 ms sample age), but its newly
created G-code fixture had not been fsynced and recovered as a zero-byte file.
The hash check refused handoff. The failure evidence was retained; the known
synthetic file was then recreated solely to retire that experiment's record.
The corrected startup flushes the G-code file and parent directory before starting
its sample stream; the repeat passed. Clearing before handoff was also rejected.

Raw traces and the summary are in `power-loss-prototype/results/bad-a8-recovery-20261011/`
and `power-loss-prototype/bad-a8-recovery-results-20261011.json`. Original config and
STM32 firmware were restored afterward; the temporary host extra was removed.
These few tests establish feasibility on this board, not reliability under a
loaded printer's electrical conditions.
