# recore-diag: a diagnostics report a user can run and share

Date: 2026-10-02. Issues: #104 (A6 crash in the field), #107 (crash recovery), #112 (A5/A6 DRAM voltage).

## Why

#104 is a user's A6 that became unreachable mid-print, with nothing left to explain it. Our own A6 in the Kossel (s/n 0256) shows what such a failure can be: a single DRAM data line (DQ10, bit 42) that flips under GPU load (Recore-CI `DRAM.md`), and two bursts of kernel Oopses with a workqueue lockup on 2026-09-06 and 09-16. Whether that is one defective unit or an A6 design issue is still open.

We need evidence from boards we cannot touch. A user should be able to run one command, get a plain-text report, and paste it on Discord, from where it is moved to GitHub by hand.

## What it is

`recore-diag`, a single bash script in `rebuild-recore` (so barebone images have it too), run over SSH:

```
sudo recore-diag              # Quick, about 2 minutes
sudo recore-diag --extended   # Extended, about 45 minutes
sudo recore-diag --last       # print the most recent report again
```

Output is plain text on the terminal, for copy and paste. Reflash can later run the same script and stream its output in the browser, like its log; that is a separate piece of work.

Nothing is uploaded. The user sees exactly what the report contains and chooses where it goes.

## Surviving a crash

- Every line also goes to `/var/lib/recore-diag/<UTC timestamp>-<mode>.txt` on the eMMC, not `/var/log` (RAM). The file is synced after each section.
- The report starts by saying where that file is.
- Each section's header is written and synced before the section runs. A report cut short by a crash therefore ends with the section that was running.
- A state file records the section in progress. The next run starts with "The previous run (<file>) ended during: <section>", and `--last` prints that report.

## Quick

Each section prints facts, then `RESULT <section>: PASS|FAIL|SKIPPED <reason>`.

1. **Board and software**
   - revision, serial number, uptime
   - `/etc/rebuild-version`; versions of `rebuild-recore`, `rebuild-printer`, `rebuild-armbian-tested` and the pinned Armbian packages
   - `uname -a`, `/proc/cmdline`, `/boot/armbianEnv.txt`, applied `user_overlays`
2. **The previous boot**
   - `/sys/fs/pstore` contents (once #107's kernel part ships; reported as unavailable before that)
   - the end of `/var/log.hdd/syslog`
   - `journalctl --list-boots`
3. **Kernel warnings**: this boot's `dmesg`, filtered for Oops, `BUG`, `Unable to handle`, `-110`, hung or blocked tasks, lockups, thermal and under-voltage messages. FAIL if any are found.
4. **Thermals and power**
   - CPU temperature and trip points
   - `scaling_cur_freq`, cooling state, governor
   - VCC-DRAM voltage (the `vcc-dram` regulator in sysfs, for #112)
   - DRAM and MBUS clocks, from debugfs `clk_summary` if available
5. **Storage**
   - the eMMC's own wear estimate (`mmc extcsd read`: life time estimates A/B, pre-EOL)
   - `df` for `/`, `/boot`, `/var/log`
   - whether any filesystem has gone read-only
6. **Klipper**
   - `klipper` and `moonraker` state; failed systemd units
   - each MCU's firmware version and the host version, via Moonraker
   - Klipper's runtime warnings
7. **Memory, short**: `memtester 64M 1`.

## Extended

All of Quick, then:

8. **Memory under load**, about 30 minutes. Three loads at once, because the Kossel's fault appears only when other bus masters load DRAM while the CPU checks it:
   - `stressapptest` over about 60% of free RAM, with all CPUs
   - the GPU: a small Python EGL (surfaceless) + GLES2 program on `/dev/dri/renderD128` that renders large textured quads into an offscreen framebuffer in a loop. Skipped, and said so, where there is no render node or EGL
   - eMMC DMA: `dd if=/dev/mmcblk2 of=/dev/null iflag=direct bs=1M` in a loop

   Then `memtester` over a larger block. FAIL on any miscompare, and the report includes the failing addresses and bit patterns as the tools print them.
9. **Temperature log**: one line every 10 seconds throughout section 8, with temperature, CPU frequency and cooling state.

Every load runs under `timeout` and is also killed by a trap, so a broken script cannot leave the board loaded.

## Safety

- **No running during a print.** Refuses while Klipper reports `printing` or `paused` (Moonraker `print_stats`).
- **Extended asks for confirmation:** "takes about 45 minutes and heats the board; do not print meanwhile". `--yes` skips the question.
- **Root needed**, and it says so if not run with `sudo`.
- **Privacy:** no NetworkManager/Wi-Fi configuration, no passwords or keys, and no `printer.cfg` contents (only MCU names and versions). The first lines tell the user to read the report before sharing it.
- **Ends with a summary:** one `RESULT` line per section, the report file path, and "Copy everything from the first line to here."

## Packaging

- `packaging/rebuild-recore/usr/bin/recore-diag`, plus a helper `usr/lib/rebuild/diag-gpu-load.py` (Python ctypes over `libEGL.so.1` and `libGLESv2.so.2`; nothing compiled).
- `rebuild-recore` Depends gains `memtester`, `stressapptest`, `mmc-utils`. All three are small Debian trixie packages.

## Testing

- **The Kossel (0256), Extended:** must FAIL in section 8 with the known DQ10 (bit 42) flips. If it passes, the load is not doing what it should, and the GPU program is the first suspect.
- **The bare A6 (0288), Extended:** the decisive "unit defect or A6 design issue" test from `DRAM.md`.
- **Quick on the A5, A6, A8 and Voron:** every section PASS or a SKIPPED that is explained.
- **A crash halfway:** start Extended on the Voron, trigger a panic during section 8, and check that after the reboot the report ends in section 8 and that the next run names it.

## Not in this piece

- The Reflash browser view (later; it reuses the script and its output format).
- Any upload.
- A Recore-CI hwtest wrapper (can follow once the output format has settled).
- Board quirks (next section).

## Future improvement: per-board quirks for marginal boards

A board that fails Extended could be made usable by running it more slowly, while good boards keep full speed: a permanent "quirk" for that one board, found and checked with `recore-diag` itself.

### What could be lowered, and where each is set

| Knob | Set by | Per-board mechanism |
|---|---|---|
| DRAM clock (648 MHz now; 624 was 11× fewer failures on the Kossel) | U-Boot SPL, at build time (`CONFIG_DRAM_CLK`) | A second U-Boot build, written to that board's boot area. The hardest one. |
| DRAM drive and termination (ODT 60 Ω: 3× fewer) | U-Boot SPL, at build time | The same as the DRAM clock |
| DRAM voltage (#112) | the kernel regulator; ideally SPL | Device tree overlay; but SPL trains DRAM before the kernel changes it |
| GPU clock, or GPU off on boards without a display | device tree (`assigned-clock-rates`, `status`) | Device tree overlay, the same way as #111's thermal overlay |
| CPU top speed | cpufreq | Overlay dropping the high OPPs, or a cpufreq cap |

### Shape

- `recore-diag --quirk <name>` applies a named quirk, and `--quirk none` removes it.
- Then it suggests rerunning Extended. A quirk counts only if the same test that failed now passes.
- The report always lists the quirks in force, so a shared report never hides that a board runs slowed down.
- **Where it lives.** It has to survive both Rebuild updates and a reflash.
  - The eMMC boot partition (`mmcblk2boot0`) already holds the board's revision, which `get-recore-revision` reads, and a reflash does not touch it. Storing quirks next to the revision would keep them with the board.
  - `rebuild-recore` and Reflash would then apply them at install and boot.

### Caveat from the Kossel

On the Kossel, both levers made the fault rarer in proportion to the margin they bought, and neither removed it. That is the signature of a marginal connection. A quirk can turn a board that fails in minutes into one that fails in weeks, and that board then passes a 45-minute test.

So for DRAM, a quirk should be recorded as "mitigated, not fixed", and the report should say so. The GPU-off quirk is different: it removes the load that exposes the fault. It is the one most likely to make a marginal A6 dependable for printing.
