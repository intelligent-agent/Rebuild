#!/bin/bash
# Validates a freshly-flashed Rebuild image over SSH.
#
# Handles the forced first-login password change if the board is still
# on the factory default (debian:temppwd, set in prep_install.sh),
# detects which image variant is running (barebone/mainsail/fluidd/
# octoprint) from /etc/rebuild-version, and checks that the systemd
# services expected for that variant are active.
#
# This is the first, "fully scriptable" tier from issue #67 - just the
# systemd check for now. More checks (Klipper config, update_manager,
# webcam, wifi, USB gadget) can be added the same way later.
#
# Usage: ./validate-image.sh [host] [new-password]
#   host          IP or hostname of the board. Defaults to recore.local.
#   new-password  password to set if the board is still on the factory
#                 default. Defaults to "rebuildtest".
#
# Repeated runs against the same IP across different flashed images
# will have a different SSH host key each time - this is expected for
# a test rig, so host key checks are isolated to a throwaway
# known_hosts file rather than touching ~/.ssh/known_hosts or
# disabling the check outright.

set -euo pipefail

HOST="${1:-recore.local}"
NEW_PASSWORD="${2:-rebuildtest}"
DEFAULT_PASSWORD="temppwd"
SSH_USER="debian"
ROOT_USER="root"
SSH_OPTS=(-o ConnectTimeout=8 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new)

run_remote() {
  "${SSH_CMD[@]}" "$@"
}

echo "== Establishing SSH access to ${HOST} =="

if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${HOST}" true 2>/dev/null; then
  echo "Using existing SSH key access (debian)."
  SSH_CMD=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${HOST}")
elif sshpass -p "$NEW_PASSWORD" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" true 2>/dev/null; then
  echo "debian password already set to the expected value."
  SSH_CMD=(sshpass -p "$NEW_PASSWORD" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}")
elif sshpass -p "$DEFAULT_PASSWORD" ssh "${SSH_OPTS[@]}" "${ROOT_USER}@${HOST}" true 2>/dev/null; then
  # barebone has its own prep_install() in customize-image-barebone.sh
  # that only sets root:temppwd directly via chpasswd (no forced
  # expiry) - it never sources prep_install.sh, so there is no debian
  # user/password to fall back to on this variant at all.
  echo "Using root with the factory default password (barebone-style)."
  SSH_CMD=(sshpass -p "$DEFAULT_PASSWORD" ssh "${SSH_OPTS[@]}" "${ROOT_USER}@${HOST}")
else
  echo "No key access, default password not accepted as-is - attempting first-login password change (debian)..."
  expect -c "
    set timeout 30
    spawn ssh ${SSH_OPTS[*]} ${SSH_USER}@${HOST}
    expect {
      -re {[Cc]urrent password:} { send \"${DEFAULT_PASSWORD}\r\"; exp_continue }
      -re {[Nn]ew password:} { send \"${NEW_PASSWORD}\r\"; exp_continue }
      -re {[Rr]etype} { send \"${NEW_PASSWORD}\r\"; exp_continue }
      -re {[Pp]assword:} { send \"${DEFAULT_PASSWORD}\r\"; exp_continue }
      -re {\\\$\s*$} { send \"exit\r\" }
      timeout { puts \"TIMEOUT waiting for password-change prompts\"; exit 1 }
      eof
    }
  "
  if ! sshpass -p "$NEW_PASSWORD" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" true 2>/dev/null; then
    echo "Password change did not take effect as expected. Aborting." >&2
    exit 1
  fi
  echo "Password changed successfully (now: ${NEW_PASSWORD})."
  SSH_CMD=(sshpass -p "$NEW_PASSWORD" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}")
fi

echo
echo "== Detecting image variant =="

REBUILD_VERSION=$(run_remote cat /etc/rebuild-version 2>/dev/null || true)
if [ -z "$REBUILD_VERSION" ]; then
  echo "Could not read /etc/rebuild-version on the board." >&2
  exit 1
fi
echo "rebuild-version: ${REBUILD_VERSION}"

case "$REBUILD_VERSION" in
  rebuild-barebone-*)  VARIANT=barebone ;;
  rebuild-mainsail-*)  VARIANT=mainsail ;;
  rebuild-fluidd-*)    VARIANT=fluidd ;;
  rebuild-octoprint-*) VARIANT=octoprint ;;
  *)
    echo "Unrecognized rebuild-version format: ${REBUILD_VERSION}" >&2
    exit 1
    ;;
esac
echo "Variant: ${VARIANT}"

BASE_SERVICES=(NetworkManager ssh)
case "$VARIANT" in
  fluidd)    EXTRA_SERVICES=(klipper moonraker nginx KlipperScreen ustreamer) ;;
  mainsail)  EXTRA_SERVICES=(klipper moonraker nginx KlipperScreen ustreamer) ;;
  octoprint) EXTRA_SERVICES=(klipper octoprint ustreamer toggle weston) ;;
  barebone)  EXTRA_SERVICES=() ;;
esac
SERVICES=("${BASE_SERVICES[@]}" "${EXTRA_SERVICES[@]}")

echo
echo "== Checking systemd services (${VARIANT}) =="

FAIL=0
for svc in "${SERVICES[@]}"; do
  STATE=$(run_remote systemctl is-active "$svc" 2>/dev/null || echo "unknown")
  if [ "$STATE" = "active" ]; then
    printf '  [OK]   %s\n' "$svc"
  else
    printf '  [FAIL] %s (%s)\n' "$svc" "$STATE"
    FAIL=1
  fi
done

echo
if [ "$VARIANT" != "barebone" ]; then
  echo "== Checking rebuild-first-run.service completed =="

  # Type=oneshot + RemainAfterExit=yes + Restart=on-failure means a
  # crash-looping instance (e.g. flash-stm32 failing every attempt) can
  # transiently look "active" or "activating" depending on exactly when
  # this happens to run - is-active is not a reliable success signal
  # here, and this service isn't in the SERVICES loop above for that
  # reason. Its own last action on success is to disable itself (see
  # rebuild-first-run), so "disabled" is the one state that can only be
  # reached by actually completing - "enabled" means it's still
  # pending, retrying, or has never successfully run.
  #
  # Only installed on fluidd/mainsail/octoprint - barebone has no
  # Klipper/STM32 setup, so the unit doesn't exist there at all.
  # systemctl is-enabled exits 1 for "disabled" (and other non-enabled
  # states) even though it correctly prints "disabled" to stdout - the
  # `|| echo unknown` pattern used elsewhere in this script only works
  # for commands where a non-zero exit means "no usable output", which
  # isn't true here, so it was discarding the correctly-captured value
  # and always reporting "unknown" instead. Capture output and exit
  # status separately: `|| true` just keeps set -e from aborting on the
  # expected non-zero exit, without touching what got captured.
  FIRST_RUN_STATE=$(run_remote systemctl is-enabled rebuild-first-run.service 2>/dev/null) || true
  FIRST_RUN_STATE="${FIRST_RUN_STATE:-unknown}"
  if [ "$FIRST_RUN_STATE" = "disabled" ]; then
    printf '  [OK]   rebuild-first-run.service completed (disabled itself)\n'
  else
    printf '  [FAIL] rebuild-first-run.service did not complete (state: %s)\n' "$FIRST_RUN_STATE"
    FAIL=1
  fi
  echo
fi
if [ "$FAIL" -eq 0 ]; then
  echo "All expected systemd services are active."
else
  echo "One or more services are not active." >&2
fi

exit $FAIL
