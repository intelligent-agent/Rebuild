#!/usr/bin/env python3
# This file may be distributed under the terms of the GNU GPLv3 license.
#
# Sets the AR100/ARISC clock source. Upstream TF-A leaves this on the
# 24MHz oscillator; Recore needs the faster PERIPH0-derived clock for
# the AR100 core to run Klipper's motion-control firmware. This used
# to be done by a local TF-A patch (mmio_write_32 in
# bl31_early_platform_setup2), but that reaches into Klipper's own
# territory, so it's done here instead, right before flash-ar100.py
# runs, while the AR100 core is still held in reset.
import argparse
import mmap

# mmap() requires a page-aligned offset, so map the page containing
# R_PRCM and index into it with R_PRCM_OFFSET, rather than mapping
# R_PRCM_BASE directly.
R_PRCM_PAGE_BASE = 0x01F01000
R_PRCM_OFFSET = 0x400

CLK_HOSC = 1 << 16
CLK_PERIPH0 = 2 << 16 | 1 << 8

parser = argparse.ArgumentParser(description='Set the AR100/ARISC clock source')
parser.add_argument('--hosc', action='store_true',
                     help='use HOSC (24MHz) instead of PERIPH0 (300MHz)')
args = parser.parse_args()

value = CLK_HOSC if args.hosc else CLK_PERIPH0

with open("/dev/mem", "w+b") as f:
    prcm = mmap.mmap(f.fileno(), length=mmap.PAGESIZE, offset=R_PRCM_PAGE_BASE)
    prcm[R_PRCM_OFFSET:R_PRCM_OFFSET + 4] = value.to_bytes(4, byteorder='little')
    prcm.close()
