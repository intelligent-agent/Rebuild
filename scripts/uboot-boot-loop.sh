#!/bin/bash
# Reboot a Recore N times, capture the U-Boot output over serial, and report
# how many boots enumerated USB cleanly.
#
# This exists because the failures it measures are intermittent (historically
# ~50% for enumeration, ~21% for the uInitrd read - see Reflash#88). A single
# boot proves nothing either way, so any claim about a U-Boot change needs a
# batch of boots with the results counted mechanically.
#
# The only place the result appears is the serial console during U-Boot -
# Linux re-enumerates independently once it starts, so it cannot be read
# after boot. The serial port must therefore be free: close minicom/screen
# first.
#
# Usage: ./uboot-boot-loop.sh [cycles] [serial-dev]
#   cycles      number of reboots (default 10)
#   serial-dev  default /dev/ttyUSB0
#
# Env overrides:
#   REFLASH_HOST   host running Reflash from USB   (default recore.local)
#   EMMC_HOST      host running Rebuild from eMMC  (default recore.local)
#   EMMC_USER/PW   ssh credentials for the eMMC OS (default debian/rebuildtest)

set -uo pipefail

CYCLES="${1:-10}"
SERIAL="${2:-/dev/ttyUSB0}"
REFLASH_HOST="${REFLASH_HOST:-recore.local}"
EMMC_HOST="${EMMC_HOST:-recore.local}"
EMMC_USER="${EMMC_USER:-debian}"
EMMC_PW="${EMMC_PW:-rebuildtest}"

OUT="uboot-bootloop-$(date +%Y%m%d-%H%M%S).log"
SSHOPT="-o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if ! [ -c "$SERIAL" ]; then
	echo "No such serial device: $SERIAL" >&2; exit 1
fi
if command -v lsof >/dev/null && lsof "$SERIAL" >/dev/null 2>&1; then
	echo "$SERIAL is held by another process (minicom/screen?). Close it first." >&2
	lsof "$SERIAL" >&2
	exit 1
fi

stty -F "$SERIAL" 115200 raw -echo
cat "$SERIAL" >> "$OUT" &
CATPID=$!
trap 'kill $CATPID 2>/dev/null' EXIT

# The board may come up either in Reflash (booted from USB) or in Rebuild on
# eMMC (if the USB boot failed and it fell through) - so try every route.
reboot_board() {
	curl -s -m 5 -X PUT "http://${REFLASH_HOST}/api/reboot_board" >/dev/null 2>&1 && return 0
	sshpass -p "$EMMC_PW" ssh $SSHOPT "${EMMC_USER}@${EMMC_HOST}" "sudo systemctl reboot" 2>/dev/null && return 0
	return 1
}

wait_up() {
	local t
	for t in $(seq 1 60); do
		curl -s -m 3 "http://${REFLASH_HOST}/api/get_info" >/dev/null 2>&1 && { echo "    up: Reflash (USB)"; return 0; }
		sshpass -p "$EMMC_PW" ssh $SSHOPT "${EMMC_USER}@${EMMC_HOST}" true 2>/dev/null && { echo "    up: eMMC OS (USB boot did not take)"; return 0; }
		sleep 5
	done
	echo "    TIMEOUT waiting for the board"; return 1
}

echo "Logging serial to $OUT"
for i in $(seq 1 "$CYCLES"); do
	echo "===== BOOT $i/$CYCLES $(date +%H:%M:%S) =====" >> "$OUT"
	echo "=== boot $i/$CYCLES  reboot $(date +%H:%M:%S)"
	reboot_board || echo "    !! could not issue reboot"
	sleep 20
	wait_up
	sleep 3
done

kill $CATPID 2>/dev/null
echo
"$(dirname "$0")/uboot-boot-parse.py" "$OUT"
