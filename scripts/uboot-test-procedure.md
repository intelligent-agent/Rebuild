# Testing U-Boot changes on a Recore

Procedure for iterating on U-Boot for Recore without rebuilding a whole
Armbian image each time. Loop is roughly a minute: edit → build → flash →
reboot.

Context and findings: [Reflash#88](https://github.com/intelligent-agent/Reflash/issues/88).

## What owns what

U-Boot, its device tree and `BOOTBRANCH` all belong to the Armbian build in
this repo — not to Reflash. Reflash only surfaces USB problems more visibly
because it is the thing booting a ~100 MB initrd off USB.

- Version: **v2024.01**, pinned by `BOOTBRANCH="tag:v2024.01"` in
  `config/sources/families/include/sunxi_common.inc`
- Board config: `configs/recore_defconfig` (`BOOTCONFIG` in `config/boards/recore.csc`)
- U-Boot's own DT: `arch/arm/dts/sun50i-a64-recore.dts` — note this is
  **separate** from the kernel DT in `userpatches/kernel/`. Changing one does
  not change the other.

## One-time setup

Work tree (Armbian's own checkout, patches already applied):

```
cd build-barebone/cache/sources/u-boot-worktree/u-boot/v2024.01
```

It is root-owned after an Armbian build, so take it first:

```
sudo chown -R "$USER:$USER" .
```

Needed: `aarch64-linux-gnu-gcc`, and `bl31.bin` — already present in the
worktree root from the last Armbian build.

> Armbian may `git reset` this worktree on its next build and discard
> everything here. Anything worth keeping has to become a patch under
> `userpatches/u-boot/u-boot-sunxi/`.

## Build

```
make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-gnu- BL31=bl31.bin SCP=/dev/null
```

**Use the bare `make`.** Asking for the image by name —
`make u-boot-sunxi-with-spl.bin` — reports `Nothing to be done` even when
source has changed, because it does not re-trigger the dependency chain. That
silently flashes a stale binary and wastes a whole test cycle.

Confirm you built what you think you did:

```
strings -a u-boot-sunxi-with-spl.bin | grep -o "U-Boot 2024\.01[^)]*)"
```

The build timestamp in that string is the only reliable way to tell binaries
apart on the board later.

### On comparing against Armbian's own build

A local build will not be byte-identical to one from `compile.sh`, because
Armbian builds inside an Ubuntu container with a different toolchain (binutils
2.42 vs the host's Debian 2.44 — a ~2.5 KB size difference). The Armbian
version string (`...-S866c-P973d-...`) covers source + patches only, so if that
matches, the code is the same and only the compiler differs. Flash an
unmodified build first and confirm it boots before attributing anything to a
source change.

## Flash to the board

U-Boot lives on the eMMC at a 8 KiB offset, and can be replaced from a running
Linux on the board.

**Back it up first** — `/tmp` on the board is tmpfs and will not survive the
reboot, so pull the copy to the host:

```
ssh debian@recore.local "sudo dd if=/dev/mmcblk2 bs=1024 skip=8 count=1024 of=/tmp/uboot-backup.bin status=none"
scp debian@recore.local:/tmp/uboot-backup.bin ./uboot-backup.bin
```

Write and verify:

```
scp u-boot-sunxi-with-spl.bin debian@recore.local:/tmp/
ssh debian@recore.local "
  sudo dd if=/tmp/u-boot-sunxi-with-spl.bin of=/dev/mmcblk2 bs=1024 seek=8 conv=notrunc status=none
  sync
  sudo dd if=/dev/mmcblk2 bs=1024 skip=8 status=none | head -c \$(stat -c%s /tmp/u-boot-sunxi-with-spl.bin) | md5sum
"
md5sum u-boot-sunxi-with-spl.bin
```

The two md5s must match. If they do not, do not reboot.

If a bad U-Boot does get written the board will not boot, and the on-board
backup is gone with `/tmp` — recovery is FEL or re-flashing the eMMC, using the
host-side copy.

## Measure

The failures are intermittent (historically ~50% for enumeration, ~21% for the
`uInitrd` read), so single boots are meaningless. Use the loop:

```
# close minicom/screen first - the script needs the serial port
./scripts/uboot-boot-loop.sh 10
```

It reboots N times, captures the serial console, and prints a per-cycle table
plus a summary. Re-parse an existing log with
`./scripts/uboot-boot-parse.py <log>`.

### Two useful rig setups

- **Enumeration only** — wipe a USB drive (`sudo wipefs -a /dev/sdX` plus
  zeroing the first 16 MB) and leave it plugged in. It still enumerates as a
  mass-storage device but has nothing bootable, so the board falls through to
  eMMC every cycle. Fast, and repeatable without ever booting Reflash.
- **Full path** — put a real Reflash image on the drive. This is the only way
  to exercise the ~100 MB `uInitrd` bulk read, which is where the second half
  of #88 lives.

### Reading the numbers

With a stick present, `6 USB Device(s) found` is healthy and `5` means one
device failed to enumerate (accompanied by `EHCI timed out on TD -
token=0x80008c80`). Without a stick it is 5 healthy / 4 degraded.

Sample sizes matter, and it is easy to fool yourself here:

| Baseline | 10 clean boots means |
|---|---|
| 50% (enumeration, pre-fix) | p ≈ 0.001 — solid |
| 21% (uInitrd, pre-fix) | p ≈ 0.095 — weak |
| 8% (uInitrd residual after the enumeration fix) | p ≈ 0.43 — nothing at all |

So 10 cycles settles enumeration but says essentially nothing about the bulk
read; that needs 30+.

Ideally also run a **matched control**: reflash the original U-Boot and repeat
the identical cycles on the same drive, power source and eMMC image. Comparing
against historical logs taken under different conditions is not a controlled
comparison. Power source in particular is known to matter — #88 reports 12–24 V
behaves better than USB-C-only.

## Current state of the fix

Applied in the worktree, **not committed**, and not yet a `userpatches` patch:

| File | Change |
|---|---|
| `board/sunxi/board.c` | `#include <power/regulator.h>` and `regulators_enable_boot_on()` in `board_init()` |
| `configs/recore_defconfig` | dropped `regulator status` from `CONFIG_PREBOOT` |

Both carry comments explaining why. Measured result: 20/20 clean boots against
a ~50% enumeration failure rate. The `uInitrd` half is not yet proven — see the
table above.

Once regulators are actually probed, `startup-delay-us` on individual rails
becomes usable, since U-Boot's fixed-regulator driver honours it
(`drivers/power/regulator/fixed.c`). That is the declarative lever for tuning
power-on settle time if more is needed.
