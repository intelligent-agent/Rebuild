#!/usr/bin/env python3
"""Tally USB enumeration results from a captured U-Boot serial log.

Split on "resetting USB..." (one per boot) and report, per cycle:

  ndev        devices found on the EHCI bus (usb@1c1b000).
              With a USB stick present 6 == healthy, 5 == one device failed
              to enumerate. Without a stick it is 5 healthy / 4 degraded.
  stor        storage devices found
  src         whether the boot script came off usb or mmc
  initrdFail  "Failed to load '/uInitrd'" - the ~100MB bulk read failed
  20KB-TO     count of token=0x50008d80 (a stalled 20480-byte bulk qTD)

Usage: uboot-boot-parse.py <logfile>
"""
import re
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__)

log = open(sys.argv[1], errors="replace").read()
cycles = re.split(r"resetting USB\.\.\.", log)[1:]
if not cycles:
    sys.exit("No boot cycles found (no 'resetting USB...' in the log)")

print(f"{'#':<4}{'ndev':<6}{'stor':<6}{'src':<6}{'initrdFail':<12}{'badCRC':<8}{'20KB-TO':<9}{'booted'}")

counts, initrd_fail, from_usb = {}, 0, 0
for i, c in enumerate(cycles, 1):
    m = re.search(
        r"usb@1c1b000 for devices\.\.\.\s*(?:EHCI timed out[^\n]*\n[^\n]*\n)?\s*(\d+) USB Device", c)
    ndev = m.group(1) if m else "?"
    ms = re.search(r"(\d+) Storage Device", c)
    stor = ms.group(1) if ms else "?"
    src = "usb" if "Boot script loaded from usb" in c else (
        "mmc" if "Boot script loaded from mmc" in c else "?")
    fail = "Failed to load '/uInitrd'" in c
    crc = "Bad Data CRC" in c
    n50 = c.count("token=0x50008d80")
    booted = "Starting kernel" in c

    counts[ndev] = counts.get(ndev, 0) + 1
    initrd_fail += fail
    from_usb += (src == "usb")
    print(f"{i:<4}{ndev:<6}{stor:<6}{src:<6}{str(fail):<12}{str(crc):<8}{n50:<9}{booted}")

n = len(cycles)
print(f"\ncycles                 : {n}")
print("device counts          : " + ", ".join(f"{k} devices x{v}" for k, v in sorted(counts.items())))
print(f"booted from USB        : {from_usb}/{n}")
print(f"uInitrd load failures  : {initrd_fail}/{n}")
print("\nNote: at a ~50% enumeration failure rate, 10 clean boots is p~0.001;")
print("but for the uInitrd read (~8-21% baseline) 10 boots proves little -")
print("30+ cycles are needed to say anything about that path.")
