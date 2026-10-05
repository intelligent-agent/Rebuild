# recore-diag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `recore-diag` command in `rebuild-recore` that prints a plain-text diagnostics report (Quick about 2 minutes, Extended about 45 minutes), saved section by section to the eMMC so a crash leaves a report that shows where it stopped.

**Architecture:**
- **A thin bash entry point** (`/usr/bin/recore-diag`) sources three small libraries under `/usr/lib/rebuild/diag/`:
  - `report.sh`: the crash-safe report writer and run state;
  - `sections.sh`: one function per report section;
  - `memory.sh`: the memory tests and the background loads.
- **A Python ctypes helper** (`/usr/lib/rebuild/diag-gpu-load.py`) loads the GPU through EGL surfaceless.
- **Tests:** the libraries read the system through overridable roots (`DIAG_DIR`, `DIAG_SYS`, `DIAG_PROC`, `DIAG_MOONRAKER`), so bats tests run off the board. The hardware behaviour is verified on Recore-CI cells.

**Tech Stack:** bash, bats (tests), Python 3 ctypes with Mesa's `libEGL.so.1`/`libGLESv2.so.2`, Debian trixie packages `memtester`, `stressapptest`, `mmc-utils`.

**Spec:** `docs/superpowers/specs/2026-10-02-recore-diag-design.md`. Everything above "Future improvement: per-board quirks" is in scope; the quirks and margin search are not.

## Global Constraints

- **Commands:** `sudo recore-diag` (Quick), `sudo recore-diag --extended`, `sudo recore-diag --last`; `--yes` skips Extended's confirmation.
- **Report file:** `/var/lib/recore-diag/<UTC timestamp>-<mode>.txt` on the eMMC, never `/var/log` (RAM).
- **Section lifecycle:** each section's header is written and synced before the section runs; the file is synced after each section.
- **Result lines:** every section ends with `RESULT <section>: PASS|FAIL|SKIPPED <reason>`.
- **Summary:** the report ends with every RESULT line, the report path, and "Copy everything from the first line to here."
- **An unfinished previous run** is announced: "The previous run (<file>) ended during: <section>".
- **Refuse while printing:** refuses while Moonraker's `print_stats.state` is `printing` or `paused`.
- **Extended confirmation:** asks "takes about 45 minutes and heats the board; do not print meanwhile". `--yes` skips it.
- **Root required:** says so if not root.
- **Privacy:** no NetworkManager or Wi-Fi configuration, no passwords or keys, no `printer.cfg` contents; the first lines tell the user to read the report before sharing.
- **Loads are bounded:** every load runs under `timeout` and is also killed by a trap.
- **Packaging:** `rebuild-recore` Depends gains `memtester`, `stressapptest`, `mmc-utils`, `python3`.
- **Commits:** author `elias@iagent.no`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on branch `recore-diag`.

## Review Focus

1. **Killed mid-section** (crash, Ctrl-C, ssh dropped): the file must end with that section's header, and the next run must name it. → Task 1 test "a killed run is named by the next one"; Task 4 test "interrupting the script stops every load".
2. **Barebone image or Moonraker down:** the Klipper section and the printing check must not hang or fail the run; Klipper is SKIPPED and the print check treats "no answer" as not printing. → Task 3 tests "Klipper is skipped when Moonraker does not answer" and "an unreachable Moonraker is not printing".
3. **No GPU stack** (no render node, no Mesa, no python3 EGL): Extended still runs, and says the GPU load was not running and why. → Task 4 test "a missing GPU helper is reported, not fatal".
4. **Secrets in logs:** syslog lines quoted in the report must not carry `psk`, `password`, `passphrase` or `secret`. → Task 3 test "secrets are dropped from the syslog tail".
5. **Report directory missing or first run:** `--last` with no reports must print a clear message and exit non-zero, not error out of `ls`. → Task 1 test "--last with no reports".

---

### Task 1: The report writer and run state

**Files:**
- Create: `packaging/rebuild-recore/usr/lib/rebuild/diag/report.sh`
- Test: `packaging/tests/diag-report.bats`
- Modify: `.github/workflows/packages.yml` (run the tests before building)

**Interfaces:**
- Produces (sourced by later tasks):
  - `DIAG_DIR`, defaulting to `/var/lib/recore-diag`; `DIAG_FILE`, the path of the open report.
  - `diag_open MODE` creates the report file.
  - `diag_out [TEXT...]` prints its arguments, or stdin when given none, to the terminal and the file.
  - `diag_sync` syncs the report file to disk.
  - `diag_section NAME` writes the header and records NAME as in progress, synced.
  - `diag_result NAME STATUS [REASON]` writes `RESULT NAME: STATUS REASON` and keeps it for the summary.
  - `diag_close` writes the summary and marks the run done.
  - `diag_failed` exits 0 if any result is FAIL.
  - `diag_previous` prints "The previous run (<file>) ended during: <section>" if the last run is unfinished, otherwise nothing.
  - `diag_last` prints the newest report; when there is none it prints `no reports in $DIAG_DIR` to stderr and returns 1.

- [ ] **Step 1: Write the failing tests**

`packaging/tests/diag-report.bats`:

```bash
#!/usr/bin/env bats
# recore-diag's report writer: terminal and file, crash-safe state (#104).

LIB="$BATS_TEST_DIRNAME/../rebuild-recore/usr/lib/rebuild/diag"

setup() {
    export DIAG_DIR="$BATS_TEST_TMPDIR/diag"
    . "$LIB/report.sh"
}

@test "lines go to the terminal and the report file" {
    diag_open quick
    run diag_out "hello"
    [ "$output" = "hello" ]
    grep -qx "hello" "$DIAG_FILE"
    [[ "$DIAG_FILE" == "$DIAG_DIR/"*-quick.txt ]]
}

@test "stdin is reported when no text is given" {
    diag_open quick
    printf 'a\nb\n' | diag_out >/dev/null
    [ "$(cat "$DIAG_FILE")" = "$(printf 'a\nb')" ]
}

@test "a section is recorded as in progress before it runs" {
    diag_open quick
    diag_section "Storage" >/dev/null
    grep -qx "=== Storage ===" "$DIAG_FILE"
    grep -qx "section=Storage" "$DIAG_DIR/state"
}

@test "a killed run is named by the next one" {
    ( . "$LIB/report.sh"; diag_open extended; diag_section "Memory under load" >/dev/null; kill -9 $BASHPID ) || true
    run diag_previous
    [[ "$output" == "The previous run ($DIAG_DIR/"*"-extended.txt) ended during: Memory under load" ]]
    f=$(ls "$DIAG_DIR"/*-extended.txt)
    [ "$(tail -n 1 "$f")" = "=== Memory under load ===" ]
}

@test "a finished run is not announced" {
    diag_open quick
    diag_section "Board and software" >/dev/null
    diag_result "Board and software" PASS >/dev/null
    diag_close >/dev/null
    run diag_previous
    [ -z "$output" ]
}

@test "the summary repeats every result and says where the report is" {
    diag_open quick
    diag_result "Storage" PASS >/dev/null
    diag_result "Kernel warnings" FAIL "see the lines above" >/dev/null
    run diag_close
    [[ "$output" == *"RESULT Storage: PASS"* ]]
    [[ "$output" == *"RESULT Kernel warnings: FAIL see the lines above"* ]]
    [[ "$output" == *"Report saved in $DIAG_FILE"* ]]
    [[ "$output" == *"Copy everything from the first line to here."* ]]
    diag_failed
}

@test "no FAIL means diag_failed is false" {
    diag_open quick
    diag_result "Storage" PASS >/dev/null
    diag_result "Klipper" SKIPPED "Moonraker is not answering" >/dev/null
    ! diag_failed
}

@test "--last prints the newest report" {
    diag_open quick; diag_out "old" >/dev/null
    sleep 1
    diag_open extended; diag_out "new" >/dev/null
    run diag_last
    [ "$output" = "new" ]
}

@test "--last with no reports" {
    run diag_last
    [ "$status" -eq 1 ]
    [[ "$output" == "no reports in $DIAG_DIR" ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats packaging/tests/diag-report.bats`
Expected: FAIL, `report.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`packaging/rebuild-recore/usr/lib/rebuild/diag/report.sh`:

```bash
# shellcheck shell=bash
# recore-diag's report (#104): every line to the terminal and to a file on the
# eMMC - not /var/log, which is RAM - synced section by section. A section's
# header is written and synced before it runs, so a report cut short by a
# crash still ends with the section that was running, and the state file lets
# the next run say so.

DIAG_DIR=${DIAG_DIR:-/var/lib/recore-diag}
DIAG_STATE="$DIAG_DIR/state"
DIAG_FILE=""
DIAG_RESULTS=()

# diag_open MODE: start a new report file.
diag_open() {
    mkdir -p "$DIAG_DIR"
    DIAG_FILE="$DIAG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1.txt"
    : >"$DIAG_FILE"
    DIAG_RESULTS=()
}

# diag_out [TEXT...]: print a line, or stdin when given no text, to both.
diag_out() {
    if [ $# -gt 0 ]; then
        printf '%s\n' "$*" | tee -a "$DIAG_FILE"
    else
        tee -a "$DIAG_FILE"
    fi
}

diag_sync() {
    sync -f "$DIAG_FILE" 2>/dev/null || sync
}

# diag_section NAME: the header, and NAME recorded as in progress, both on
# disk before the section starts.
diag_section() {
    diag_out ""
    diag_out "=== $1 ==="
    printf 'file=%s\nsection=%s\n' "$DIAG_FILE" "$1" >"$DIAG_STATE"
    sync -f "$DIAG_STATE" 2>/dev/null || true
    diag_sync
}

# diag_result NAME PASS|FAIL|SKIPPED [REASON]
diag_result() {
    local line="RESULT $1: $2${3:+ $3}"
    diag_out "$line"
    DIAG_RESULTS+=("$line")
    diag_sync
}

# diag_close: the summary, and the run marked finished.
diag_close() {
    local r
    diag_out ""
    diag_out "=== Summary ==="
    for r in "${DIAG_RESULTS[@]}"; do
        diag_out "$r"
    done
    diag_out "Report saved in $DIAG_FILE"
    diag_out "Copy everything from the first line to here."
    printf 'file=%s\nsection=done\n' "$DIAG_FILE" >"$DIAG_STATE"
    diag_sync
}

diag_failed() {
    printf '%s\n' "${DIAG_RESULTS[@]}" | grep -q ': FAIL'
}

# diag_previous: if the last run did not finish, say where it stopped.
diag_previous() {
    [ -f "$DIAG_STATE" ] || return 0
    local file section
    file=$(sed -n 's/^file=//p' "$DIAG_STATE")
    section=$(sed -n 's/^section=//p' "$DIAG_STATE")
    if [ -n "$section" ] && [ "$section" != done ]; then
        echo "The previous run ($file) ended during: $section"
    fi
}

# diag_last: print the newest report.
diag_last() {
    local f
    f=$(ls -1t "$DIAG_DIR"/*.txt 2>/dev/null | head -n 1)
    if [ -z "$f" ]; then
        echo "no reports in $DIAG_DIR" >&2
        return 1
    fi
    cat "$f"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats packaging/tests/diag-report.bats`
Expected: 9 tests, 0 failures. (`--last with no reports` checks `$output`, which bats fills from stderr too.)

- [ ] **Step 5: Run the tests in CI before the packages are built**

In `.github/workflows/packages.yml`, insert before the `Build packages` step:

```yaml
    - name: Test packages
      # bats in the same throwaway container build-debs uses: the runner has
      # docker but not bats.
      run: |
        docker run --rm -v "$PWD:/w" -w /w debian:trixie sh -c \
          'apt-get update -qq && apt-get install -y -qq --no-install-recommends bats >/dev/null && bats packaging/tests'
```

- [ ] **Step 6: Commit**

```bash
git add packaging/rebuild-recore/usr/lib/rebuild/diag/report.sh packaging/tests/diag-report.bats .github/workflows/packages.yml
git -c user.email=elias@iagent.no commit -m "recore-diag: a crash-safe report writer (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The `recore-diag` command

**Files:**
- Create: `packaging/rebuild-recore/usr/bin/recore-diag`
- Test: `packaging/tests/diag-cli.bats`

**Interfaces:**
- Consumes: everything from Task 1.
- Consumes, from Tasks 3 and 4 (stubbed in this task's tests via `DIAG_LIB`):
  - `diag_sections MODE` prints section function names, space-separated;
  - `diag_printing` returns 0 while printing.
- Produces:
  - **Exit codes:** 0 when no section FAILs, 1 when any does, 2 when refused, cancelled or used wrongly.
  - **`DIAG_LIB`** overrides the library directory (default `/usr/lib/rebuild/diag`).
  - **`DIAG_ALLOW_USER=1`** skips the root check. For tests only.

- [ ] **Step 1: Write the failing tests**

`packaging/tests/diag-cli.bats`:

```bash
#!/usr/bin/env bats
# recore-diag's command line: modes, refusals, summary and exit status.

ROOT="$BATS_TEST_DIRNAME/../rebuild-recore"
CMD="$ROOT/usr/bin/recore-diag"

setup() {
    export DIAG_DIR="$BATS_TEST_TMPDIR/diag" DIAG_ALLOW_USER=1
    # The real report writer, with stub sections.
    export DIAG_LIB="$BATS_TEST_TMPDIR/lib"
    mkdir -p "$DIAG_LIB"
    cp "$ROOT/usr/lib/rebuild/diag/report.sh" "$DIAG_LIB/"
    cat >"$DIAG_LIB/sections.sh" <<'EOF'
diag_printing() { [ -n "${STUB_PRINTING:-}" ]; }
diag_sections() { echo sec_a; [ "$1" = extended ] && echo sec_b; }
sec_a() { diag_section A; diag_out "a ran"; diag_result A "${STUB_A:-PASS}"; }
sec_b() { diag_section B; diag_out "b ran"; diag_result B PASS; }
EOF
    : >"$DIAG_LIB/memory.sh"
}

@test "Quick runs the quick sections and ends with the summary" {
    run "$CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recore-diag quick report"* ]]
    [[ "$output" == *"Read it before sharing"* ]]
    [[ "$output" == *"a ran"* ]]
    [[ "$output" != *"b ran"* ]]
    [[ "$output" == *"=== Summary ==="*"RESULT A: PASS"* ]]
}

@test "a FAIL makes the exit status 1" {
    STUB_A=FAIL run "$CMD"
    [ "$status" -eq 1 ]
}

@test "Extended asks first, and no means no" {
    run "$CMD" --extended <<<"n"
    [ "$status" -eq 2 ]
    [[ "$output" == *"about 45 minutes"* ]]
    [[ "$output" != *"a ran"* ]]
}

@test "Extended with --yes runs every section" {
    run "$CMD" --extended --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"a ran"*"b ran"* ]]
}

@test "it refuses while the printer is printing" {
    STUB_PRINTING=1 run "$CMD"
    [ "$status" -eq 2 ]
    [[ "$output" == *"printing"* ]]
    [ ! -d "$DIAG_DIR" ] || [ -z "$(ls "$DIAG_DIR")" ]
}

@test "it needs root" {
    [ "$(id -u)" -ne 0 ] || skip "the tests are running as root"
    DIAG_ALLOW_USER= run "$CMD"
    [ "$status" -eq 2 ]
    [[ "$output" == *"sudo recore-diag"* ]]
}

@test "an unfinished run is named at the top of the next report" {
    mkdir -p "$DIAG_DIR"
    printf 'file=%s\nsection=%s\n' "$DIAG_DIR/x-extended.txt" "Memory under load" >"$DIAG_DIR/state"
    run "$CMD"
    [[ "$output" == *"The previous run ($DIAG_DIR/x-extended.txt) ended during: Memory under load"* ]]
}

@test "--last prints the previous report" {
    "$CMD" >/dev/null
    run "$CMD" --last
    [ "$status" -eq 0 ]
    [[ "$output" == *"recore-diag quick report"* ]]
}

@test "an unknown option prints the usage" {
    run "$CMD" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"sudo recore-diag --extended"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats packaging/tests/diag-cli.bats`
Expected: FAIL, `recore-diag: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`packaging/rebuild-recore/usr/bin/recore-diag` (mode 755):

```bash
#!/bin/bash
# A diagnostics report for a Recore, to copy from the terminal and share (#104).
#
#   sudo recore-diag              Quick, about 2 minutes
#   sudo recore-diag --extended   adds memory under load, about 45 minutes
#   sudo recore-diag --last       print the most recent report again
#
# Saved as it runs to /var/lib/recore-diag; if the board crashes halfway, the
# report ends with the section that was running and the next run says so.
# Design: docs/superpowers/specs/2026-10-02-recore-diag-design.md
set -uo pipefail

LIB=${DIAG_LIB:-/usr/lib/rebuild/diag}
. "$LIB/report.sh"
. "$LIB/sections.sh"
. "$LIB/memory.sh"

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE=quick
YES=""
while [ $# -gt 0 ]; do
    case $1 in
        --extended) MODE=extended ;;
        --yes) YES=1 ;;
        --last) diag_last; exit $? ;;
        *) usage ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ] && [ -z "${DIAG_ALLOW_USER:-}" ]; then
    echo "recore-diag needs root: sudo recore-diag" >&2
    exit 2
fi
if diag_printing; then
    echo "The printer is printing - recore-diag would disturb the print. Run it when the printer is idle." >&2
    exit 2
fi
if [ "$MODE" = extended ] && [ -z "$YES" ]; then
    printf 'Extended takes about 45 minutes and heats the board; do not print meanwhile.\nContinue? [y/N] '
    read -r answer || answer=""
    case $answer in
        y|Y|yes) ;;
        *) echo "Cancelled."; exit 2 ;;
    esac
fi

previous=$(diag_previous)
diag_open "$MODE"
diag_out "recore-diag $MODE report, $(date -u '+%Y-%m-%d %H:%M UTC')"
diag_out "Saved as it runs to $DIAG_FILE"
diag_out "Read it before sharing. It contains no passwords, Wi-Fi settings or printer.cfg."
[ -z "$previous" ] || diag_out "$previous"
diag_sync

for section in $(diag_sections "$MODE"); do
    "$section"
done

diag_close
if diag_failed; then
    exit 1
fi
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats packaging/tests/`
Expected: all tests in both files pass.

- [ ] **Step 5: Commit**

```bash
chmod 755 packaging/rebuild-recore/usr/bin/recore-diag
git add packaging/rebuild-recore/usr/bin/recore-diag packaging/tests/diag-cli.bats
git -c user.email=elias@iagent.no commit -m "recore-diag: the command - modes, refusals, summary (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The Quick sections

**Files:**
- Create: `packaging/rebuild-recore/usr/lib/rebuild/diag/sections.sh`
- Test: `packaging/tests/diag-sections.bats`

**Interfaces:**
- Consumes: Task 1's `diag_*` functions.
- Produces:
  - `DIAG_SYS` (default `/sys`), `DIAG_PROC` (default `/proc`), `DIAG_MOONRAKER` (default `http://localhost:7125`).
  - `diag_printing`; `diag_sections MODE`; `diag_cmd CMD...`, which puts `$ CMD` and its indented output in the report.
  - `diag_milli VALUE`: VALUE/1000 with one decimal.
  - `diag_no_secrets`, a stdin filter that drops lines with `psk|password|passphrase|secret`.
  - `DIAG_KERNEL_PATTERN` and `diag_kernel_findings`, a stdin filter.
  - The section functions `sec_board`, `sec_previous_boot`, `sec_kernel`, `sec_thermal`, `sec_storage` and `sec_klipper`.
- Produces for Task 4: `diag_sections extended` lists `sec_memory_short` and `sec_memory_load`, which Task 4 defines in `memory.sh`. `diag_sections quick` lists `sec_memory_short` too.

- [ ] **Step 1: Write the failing tests**

`packaging/tests/diag-sections.bats`:

```bash
#!/usr/bin/env bats
# recore-diag's sections, read from fake /sys, /proc and Moonraker.

LIB="$BATS_TEST_DIRNAME/../rebuild-recore/usr/lib/rebuild/diag"

setup() {
    export DIAG_DIR="$BATS_TEST_TMPDIR/diag" DIAG_SYS="$BATS_TEST_TMPDIR/sys" DIAG_PROC="$BATS_TEST_TMPDIR/proc"
    export DIAG_MOONRAKER="http://127.0.0.1:9"    # nothing listens there
    mkdir -p "$DIAG_SYS" "$DIAG_PROC"
    . "$LIB/report.sh"
    . "$LIB/sections.sh"
    diag_open quick
}

@test "Quick lists the quick sections, Extended adds memory under load" {
    [ "$(diag_sections quick | tr -s ' \n' ' ')" = "sec_board sec_previous_boot sec_kernel sec_thermal sec_storage sec_klipper sec_memory_short " ]
    diag_sections extended | grep -qw sec_memory_load
}

@test "the kernel filter catches the Kossel's crash lines" {
    hits=$(printf '%s\n' \
        "[ 1637.48] BUG: workqueue lockup - pool cpus=0 node=0 flags=0x0 nice=0 stuck for 488s!" \
        "[ 1699.99] Unable to handle kernel paging request at virtual address fffff9ffc011bc00" \
        "[ 1700.03] Internal error: Oops: 0000000096000004 [#1]  SMP" \
        "[ 3019.73] INFO: task sh:2928 blocked for more than 120 seconds." \
        "[   12.00] mmc2: Timeout waiting for hardware interrupt." \
        "[   13.00] sunxi-mmc 1c11000.mmc: data error, sending stop command" \
        "[    1.00] usb 1-1: new high-speed USB device number 2 using ehci-platform" \
        | diag_kernel_findings)
    [ "$(printf '%s\n' "$hits" | wc -l)" -eq 6 ]
    [[ "$hits" != *"new high-speed"* ]]
}

@test "thermals read temperature, trips, frequency and the DRAM rail" {
    mkdir -p "$DIAG_SYS/class/thermal/thermal_zone0" "$DIAG_SYS/class/thermal/cooling_device0" \
             "$DIAG_SYS/devices/system/cpu/cpufreq/policy0" "$DIAG_SYS/class/regulator/regulator.7"
    echo 56123 >"$DIAG_SYS/class/thermal/thermal_zone0/temp"
    echo passive >"$DIAG_SYS/class/thermal/thermal_zone0/trip_point_0_type"
    echo 75000 >"$DIAG_SYS/class/thermal/thermal_zone0/trip_point_0_temp"
    echo 1008000 >"$DIAG_SYS/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"
    echo 1008000 >"$DIAG_SYS/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
    echo performance >"$DIAG_SYS/devices/system/cpu/cpufreq/policy0/scaling_governor"
    echo 0 >"$DIAG_SYS/class/thermal/cooling_device0/cur_state"
    echo 7 >"$DIAG_SYS/class/thermal/cooling_device0/max_state"
    echo vcc-dram >"$DIAG_SYS/class/regulator/regulator.7/name"
    echo 1500000 >"$DIAG_SYS/class/regulator/regulator.7/microvolts"
    run sec_thermal
    [[ "$output" == *"cpu temperature: 56.1 C"* ]]
    [[ "$output" == *"trip trip_point_0: passive 75.0 C"* ]]
    [[ "$output" == *"cpu frequency: 1008 MHz (max 1008, governor performance)"* ]]
    [[ "$output" == *"cooling state: 0/7"* ]]
    [[ "$output" == *"vcc-dram: 1500.0 mV"* ]]
    [[ "$output" == *"RESULT Thermals and power: PASS"* ]]
}

@test "thermals are skipped without a thermal zone" {
    run sec_thermal
    [[ "$output" == *"RESULT Thermals and power: SKIPPED"* ]]
}

@test "a kept crash log fails the previous-boot section" {
    mkdir -p "$DIAG_SYS/fs/pstore"
    printf 'Kernel panic - not syncing: sysrq triggered crash\n' >"$DIAG_SYS/fs/pstore/dmesg-ramoops-0"
    run sec_previous_boot
    [[ "$output" == *"dmesg-ramoops-0"*"Kernel panic"* ]]
    [[ "$output" == *"RESULT Previous boot: FAIL the kernel kept a crash log"* ]]
}

@test "a console log alone is not a crash" {
    mkdir -p "$DIAG_SYS/fs/pstore"
    printf 'normal shutdown\n' >"$DIAG_SYS/fs/pstore/console-ramoops-0"
    run sec_previous_boot
    [[ "$output" == *"RESULT Previous boot: PASS"* ]]
}

@test "secrets are dropped from the syslog tail" {
    run diag_no_secrets <<<"$(printf '%s\n' "wifi: connected" "psk=hunter2" "Password: x" "ok")"
    [ "$output" = "$(printf 'wifi: connected\nok')" ]
}

@test "Klipper is skipped when Moonraker does not answer" {
    run sec_klipper
    [[ "$output" == *"RESULT Klipper: SKIPPED Moonraker is not answering"* ]]
}

@test "an unreachable Moonraker is not printing" {
    ! diag_printing
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats packaging/tests/diag-sections.bats`
Expected: FAIL, `sections.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`packaging/rebuild-recore/usr/lib/rebuild/diag/sections.sh`:

```bash
# shellcheck shell=bash
# recore-diag's report sections (#104). Each one starts with diag_section and
# ends with diag_result. The roots are variables so the tests can use a fake
# /sys, /proc and Moonraker.

DIAG_SYS=${DIAG_SYS:-/sys}
DIAG_PROC=${DIAG_PROC:-/proc}
DIAG_MOONRAKER=${DIAG_MOONRAKER:-http://localhost:7125}

# Kernel messages that mean something went wrong: the crashes, lockups and
# eMMC timeouts seen on Recores (#88, #104, #107), heat and power.
DIAG_KERNEL_PATTERN='Oops|BUG:|Unable to handle|Internal error|Kernel panic|blocked for more than|soft lockup|hard LOCKUP|workqueue lockup|rcu: INFO|rcu_.*stall|-110|mmc[0-9]+: .*([Tt]imeout|error)|sunxi-mmc.*error|critical temperature|HARDWARE PROTECTION|[Uu]nder-?voltage|EXT4-fs error|I/O error|Out of memory|oom-kill'

diag_sections() {
    echo sec_board sec_previous_boot sec_kernel sec_thermal sec_storage sec_klipper sec_memory_short
    if [ "$1" = extended ]; then
        echo sec_memory_load
    fi
}

# Is the printer printing? An unreachable Moonraker (barebone, stopped) is not.
diag_printing() {
    curl -s -m 5 "$DIAG_MOONRAKER/printer/objects/query?print_stats" 2>/dev/null |
        python3 -c 'import json, sys
s = json.load(sys.stdin)["result"]["status"]["print_stats"]["state"]
sys.exit(0 if s in ("printing", "paused") else 1)' 2>/dev/null
}

diag_cmd() {
    diag_out "\$ $*"
    "$@" 2>&1 | sed 's/^/    /' | diag_out
}

diag_milli() {
    awk -v v="${1:-0}" 'BEGIN { printf "%.1f", v / 1000 }'
}

diag_no_secrets() {
    grep -viE 'psk|password|passphrase|secret' || true
}

diag_kernel_findings() {
    grep -aE "$DIAG_KERNEL_PATTERN" || true
}

sec_board() {
    diag_section "Board and software"
    diag_out "revision: $(get-recore-revision 2>/dev/null || echo unknown)"
    diag_out "serial number: $(get-serial-number 2>/dev/null || echo unknown)"
    diag_out "uptime: $(uptime -p 2>/dev/null)"
    diag_out "rebuild: $(cat /etc/rebuild-version 2>/dev/null || echo unknown)"
    diag_cmd dpkg-query -W -f '${Package} ${Version}\n' rebuild-recore rebuild-printer \
        rebuild-armbian-tested linux-image-current-sunxi64 linux-dtb-current-sunxi64 \
        linux-u-boot-recore-current armbian-bsp-cli-recore-current
    diag_cmd uname -a
    diag_cmd cat "$DIAG_PROC/cmdline"
    diag_cmd cat /boot/armbianEnv.txt
    diag_result "Board and software" PASS
}

sec_previous_boot() {
    diag_section "Previous boot"
    local p="$DIAG_SYS/fs/pstore" f crash=""
    if [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
        for f in "$p"/*; do
            diag_out "--- $(basename "$f") (last 60 lines)"
            tail -n 60 "$f" | sed 's/^/    /' | diag_out
            case $(basename "$f") in dmesg-*) crash=1 ;; esac
        done
    elif grep -qw pstore "$DIAG_PROC/filesystems" 2>/dev/null; then
        diag_out "pstore: empty - no crash log kept from the previous boot"
    else
        diag_out "pstore: not available in this kernel"
    fi
    diag_cmd journalctl --list-boots --no-pager
    if [ -f /var/log.hdd/syslog ]; then
        diag_out "--- end of /var/log.hdd/syslog"
        tail -n 40 /var/log.hdd/syslog | diag_no_secrets | sed 's/^/    /' | diag_out
    fi
    if [ -n "$crash" ]; then
        diag_result "Previous boot" FAIL "the kernel kept a crash log"
    else
        diag_result "Previous boot" PASS
    fi
}

sec_kernel() {
    diag_section "Kernel warnings"
    local hits
    hits=$(dmesg 2>/dev/null | diag_kernel_findings)
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | head -n 80 | diag_out
        diag_out "($(printf '%s\n' "$hits" | wc -l) matching lines in this boot's kernel log)"
        diag_result "Kernel warnings" FAIL "see the lines above"
    else
        diag_out "none in this boot's kernel log"
        diag_result "Kernel warnings" PASS
    fi
}

sec_thermal() {
    diag_section "Thermals and power"
    local z="$DIAG_SYS/class/thermal/thermal_zone0" c="$DIAG_SYS/class/thermal/cooling_device0"
    local f="$DIAG_SYS/devices/system/cpu/cpufreq/policy0" t n r clk
    if [ ! -f "$z/temp" ]; then
        diag_result "Thermals and power" SKIPPED "no thermal zone"
        return
    fi
    diag_out "cpu temperature: $(diag_milli "$(cat "$z/temp")") C"
    for t in "$z"/trip_point_*_type; do
        [ -f "$t" ] || continue
        n=${t%_type}
        diag_out "trip $(basename "$n"): $(cat "$t") $(diag_milli "$(cat "${n}_temp")") C"
    done
    diag_out "cpu frequency: $(( $(cat "$f/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 )) MHz (max $(( $(cat "$f/scaling_max_freq" 2>/dev/null || echo 0) / 1000 )), governor $(cat "$f/scaling_governor" 2>/dev/null))"
    diag_out "cooling state: $(cat "$c/cur_state" 2>/dev/null)/$(cat "$c/max_state" 2>/dev/null)"
    for r in "$DIAG_SYS"/class/regulator/*; do
        if [ "$(cat "$r/name" 2>/dev/null)" = vcc-dram ]; then
            diag_out "vcc-dram: $(diag_milli "$(cat "$r/microvolts" 2>/dev/null)") mV"
        fi
    done
    clk="$DIAG_SYS/kernel/debug/clk/clk_summary"
    if [ "$DIAG_SYS" = /sys ] && [ ! -f "$clk" ]; then
        mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    fi
    if [ -f "$clk" ]; then
        grep -E '^\s*(dram|mbus)\s' "$clk" | awk '{ printf "clock %s: %d MHz\n", $1, $5 / 1000000 }' | diag_out
    fi
    diag_result "Thermals and power" PASS
}

sec_storage() {
    diag_section "Storage"
    local disk eol
    disk=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n 1)
    if command -v mmc >/dev/null && [ -b "$disk" ]; then
        mmc extcsd read "$disk" 2>/dev/null | grep -E 'Life Time Estimation|Pre EOL' | sed 's/^/    /' | diag_out
        eol=$(mmc extcsd read "$disk" 2>/dev/null | sed -n 's/.*PRE_EOL_INFO\]: 0x0*//p')
    else
        diag_out "eMMC wear: not available"
    fi
    diag_cmd df -h / /boot /var/log
    if findmnt -rno OPTIONS / | grep -qE '(^|,)ro(,|$)'; then
        diag_result Storage FAIL "the root filesystem is read-only"
    elif [ "${eol:-}" = 3 ]; then
        diag_result Storage FAIL "the eMMC reports it is at the end of its life"
    else
        diag_result Storage PASS
    fi
}

sec_klipper() {
    diag_section "Klipper"
    local u failed report
    for u in klipper moonraker; do
        diag_out "$u: $(systemctl is-active "$u" 2>/dev/null)"
    done
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null)
    diag_out "failed units: ${failed:-none}"
    if ! curl -s -m 5 "$DIAG_MOONRAKER/server/info" >/dev/null 2>&1; then
        diag_result Klipper SKIPPED "Moonraker is not answering"
        return
    fi
    # One pass through Moonraker: host version and state, each MCU's firmware
    # version, and Klipper's own warnings. Prints "STATE <state>" last.
    report=$(python3 - "$DIAG_MOONRAKER" <<'EOF'
import json, sys, urllib.parse, urllib.request
base = sys.argv[1]
def get(path):
    with urllib.request.urlopen(base + path, timeout=10) as r:
        return json.load(r)["result"]
info = get("/printer/info")
print(f"klipper host: {info.get('software_version')} ({info.get('state')})")
objs = [o for o in get("/printer/objects/list")["objects"] if o.startswith("mcu")]
q = "&".join(urllib.parse.quote(o) for o in objs + ["configfile"])
st = get("/printer/objects/query?" + q)["status"]
for o in objs:
    print(f"{o}: {st.get(o, {}).get('mcu_version')}")
for w in st.get("configfile", {}).get("warnings", []):
    print(f"klipper warning: {w.get('message')}")
print(f"STATE {info.get('state')}")
EOF
    ) || report="STATE unknown"
    printf '%s\n' "$report" | grep -v '^STATE ' | diag_out
    if [ -n "$failed" ]; then
        diag_result Klipper FAIL "failed units: $(printf '%s\n' "$failed" | awk '{print $1}' | xargs)"
    elif ! printf '%s\n' "$report" | grep -qx 'STATE ready'; then
        diag_result Klipper FAIL "Klipper is not ready"
    else
        diag_result Klipper PASS
    fi
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats packaging/tests/diag-sections.bats`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add packaging/rebuild-recore/usr/lib/rebuild/diag/sections.sh packaging/tests/diag-sections.bats
git -c user.email=elias@iagent.no commit -m "recore-diag: the Quick sections (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Memory tests, background loads and the temperature log

**Files:**
- Create: `packaging/rebuild-recore/usr/lib/rebuild/diag/memory.sh`
- Modify: `packaging/rebuild-recore/usr/bin/recore-diag` (install the trap)
- Test: `packaging/tests/diag-memory.bats`

**Interfaces:**
- Consumes: Task 1's `diag_*`, and Task 3's `DIAG_SYS`, `DIAG_PROC` and `diag_milli`.
- Produces:
  - `DIAG_LOAD_PIDS` (array).
  - `diag_start_load SECONDS CMD...`: CMD in the background under `timeout`, with its PID recorded.
  - `diag_start_thermal_log INTERVAL`: a background loop of `temp ... freq ... cooling ...` lines into the report.
  - `diag_stop_loads`: kills every recorded PID and waits for them.
  - `sec_memory_short`, and `sec_memory_load`, whose duration `DIAG_SOAK_SECONDS` defaults to 1800.
  - `DIAG_GPU_LOAD`, the helper path, defaulting to `/usr/lib/rebuild/diag-gpu-load.py`.

- [ ] **Step 1: Write the failing tests**

`packaging/tests/diag-memory.bats`:

```bash
#!/usr/bin/env bats
# recore-diag's loads end, whatever happens to the script.

LIB="$BATS_TEST_DIRNAME/../rebuild-recore/usr/lib/rebuild/diag"
CMD="$BATS_TEST_DIRNAME/../rebuild-recore/usr/bin/recore-diag"

setup() {
    export DIAG_DIR="$BATS_TEST_TMPDIR/diag" DIAG_SYS="$BATS_TEST_TMPDIR/sys" DIAG_PROC="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$DIAG_SYS" "$DIAG_PROC"
    . "$LIB/report.sh"; . "$LIB/sections.sh"; . "$LIB/memory.sh"
    diag_open extended
}

@test "loads stop when asked" {
    diag_start_load 60 sleep 4241
    diag_start_load 60 sleep 4242
    diag_stop_loads
    ! pgrep -f "sleep 424[12]"
}

@test "a load ends by itself at its timeout" {
    diag_start_load 1 sleep 4243
    sleep 2
    ! pgrep -f "sleep 4243"
}

@test "interrupting the script stops every load" {
    # The real entry point, with a section that starts loads and then hangs.
    export DIAG_LIB="$BATS_TEST_TMPDIR/lib" DIAG_ALLOW_USER=1
    mkdir -p "$DIAG_LIB"
    cp "$LIB/report.sh" "$LIB/memory.sh" "$DIAG_LIB/"
    cat >"$DIAG_LIB/sections.sh" <<'EOF'
diag_printing() { return 1; }
diag_sections() { echo sec_hang; }
sec_hang() { diag_section Hang; diag_start_load 60 sleep 4244; diag_start_load 60 sleep 4245; sleep 30; }
EOF
    # Its own process group, signalled as a whole, as Ctrl-C or a dropped ssh
    # session would: bash runs the trap only once its foreground child is gone.
    setsid "$CMD" >/dev/null 2>&1 &
    pid=$!
    sleep 2
    kill -TERM -- -"$pid"
    wait "$pid" || true
    sleep 1
    ! pgrep -f "sleep 424[45]"
}

@test "memtester's verdict decides the short memory test" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho "  Stuck Address       : ok"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/memtester"
    chmod +x "$BATS_TEST_TMPDIR/bin/memtester"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sec_memory_short
    [[ "$output" == *"RESULT Memory, short: PASS"* ]]
    printf '#!/bin/sh\necho "  Bit Flip            : FAILURE: 0x00000400 != 0x00000000 at offset 0x01234567."\nexit 4\n' >"$BATS_TEST_TMPDIR/bin/memtester"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sec_memory_short
    [[ "$output" == *"FAILURE: 0x00000400"* ]]
    [[ "$output" == *"RESULT Memory, short: FAIL"* ]]
}

@test "a missing GPU helper is reported, not fatal" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for t in stressapptest memtester; do printf '#!/bin/sh\necho "Status: PASS - please verify no corrected errors"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
    printf 'MemAvailable:     500000 kB\n' >"$DIAG_PROC/meminfo"
    DIAG_GPU_LOAD=/nonexistent DIAG_SOAK_SECONDS=2 DIAG_EMMC=/nonexistent PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sec_memory_load
    [[ "$output" == *"GPU load: not running"* ]]
    [[ "$output" == *"eMMC load: not running"* ]]
    [[ "$output" == *"RESULT Memory under load: PASS"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats packaging/tests/diag-memory.bats`
Expected: FAIL, `memory.sh: No such file or directory`.

- [ ] **Step 3: Write `memory.sh`**

`packaging/rebuild-recore/usr/lib/rebuild/diag/memory.sh`:

```bash
# shellcheck shell=bash
# recore-diag's memory tests (#104). The A6 in the Kossel flips one DRAM data
# line (DQ10) only while other bus masters load DRAM - the GPU above all - as
# the CPU checks it (Recore-CI DRAM.md). So Extended runs stressapptest and
# memtester with the GPU and eMMC DMA loading DRAM at the same time.
#
# Every load runs under timeout and is recorded, and recore-diag kills them
# all from its trap: a crashed or interrupted script cannot leave the board
# loaded (a broken stop once powered off a fanless A5 at 90 C, #111).

DIAG_LOAD_PIDS=()
DIAG_GPU_LOAD=${DIAG_GPU_LOAD:-/usr/lib/rebuild/diag-gpu-load.py}
DIAG_SOAK_SECONDS=${DIAG_SOAK_SECONDS:-1800}

# diag_start_load SECONDS CMD...: CMD in the background, ended by timeout.
diag_start_load() {
    local seconds=$1
    shift
    timeout "$seconds" "$@" &
    DIAG_LOAD_PIDS+=("$!")
}

# A line every INTERVAL seconds, synced, so a crash shows the temperature trend.
diag_start_thermal_log() {
    local interval=$1
    (
        while :; do
            diag_out "$(date -u +%H:%M:%S) temp $(diag_milli "$(cat "$DIAG_SYS/class/thermal/thermal_zone0/temp" 2>/dev/null)") C freq $(( $(cat "$DIAG_SYS/devices/system/cpu/cpufreq/policy0/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 )) MHz cooling $(cat "$DIAG_SYS/class/thermal/cooling_device0/cur_state" 2>/dev/null)"
            diag_sync
            sleep "$interval"
        done
    ) &
    DIAG_LOAD_PIDS+=("$!")
}

diag_stop_loads() {
    local p
    for p in "${DIAG_LOAD_PIDS[@]}"; do
        kill "$p" 2>/dev/null
    done
    for p in "${DIAG_LOAD_PIDS[@]}"; do
        wait "$p" 2>/dev/null
    done
    DIAG_LOAD_PIDS=()
}

# memtester's output, without its progress spinner.
diag_memtester_lines() {
    tr '\b' '\n' | grep -E 'FAILURE|ok$|Loop|got|testing' | grep -vE '^\s*$' | tail -n 40
}

sec_memory_short() {
    diag_section "Memory, short"
    local out rc
    out=$(memtester 64M 1 2>&1)
    rc=$?
    printf '%s\n' "$out" | diag_memtester_lines | diag_out
    if [ "$rc" -eq 0 ]; then
        diag_result "Memory, short" PASS
    else
        diag_result "Memory, short" FAIL "memtester exit $rc"
    fi
}

sec_memory_load() {
    diag_section "Memory under load"
    local avail mb emmc gpu_out stress_out mem_out rc_s rc_m reason=""
    avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' "$DIAG_PROC/meminfo")
    mb=$(( avail * 6 / 10 ))
    diag_out "stressapptest over ${mb} MB for ${DIAG_SOAK_SECONDS}s, then memtester 256M, with these loads:"
    diag_start_thermal_log 10

    # The GPU: the load that exposes the Kossel's fault.
    gpu_out=$(mktemp)
    if [ -e "$DIAG_GPU_LOAD" ] && command -v python3 >/dev/null; then
        diag_start_load $(( DIAG_SOAK_SECONDS + 1200 )) python3 "$DIAG_GPU_LOAD" --seconds $(( DIAG_SOAK_SECONDS + 1200 )) >"$gpu_out" 2>&1
        sleep 5
        diag_out "GPU load: $(head -n 1 "$gpu_out")"
    else
        diag_out "GPU load: not running - no helper or no python3"
    fi

    # eMMC DMA: reading the disk writes into DRAM without the CPU.
    emmc=${DIAG_EMMC:-/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n 1)}
    if [ -b "$emmc" ]; then
        diag_start_load $(( DIAG_SOAK_SECONDS + 1200 )) sh -c "while :; do dd if=$emmc of=/dev/null bs=1M count=2048 iflag=direct status=none; done"
        diag_out "eMMC load: reading $emmc"
    else
        diag_out "eMMC load: not running - no eMMC root device"
    fi
    diag_sync

    stress_out=$(mktemp)
    timeout $(( DIAG_SOAK_SECONDS + 120 )) stressapptest -s "$DIAG_SOAK_SECONDS" -M "$mb" -m "$(nproc)" -W >"$stress_out" 2>&1
    rc_s=$?
    diag_out "--- stressapptest (exit $rc_s)"
    grep -aE 'Status:|[Ee]rror|miscompare|Report' "$stress_out" | tail -n 40 | sed 's/^/    /' | diag_out

    mem_out=$(mktemp)
    timeout 1080 memtester 256M 1 >"$mem_out" 2>&1
    rc_m=$?
    diag_out "--- memtester 256M (exit $rc_m)"
    diag_memtester_lines <"$mem_out" | sed 's/^/    /' | diag_out

    diag_stop_loads
    rm -f "$gpu_out" "$stress_out" "$mem_out"
    [ "$rc_s" -eq 0 ] || reason="stressapptest exit $rc_s"
    [ "$rc_m" -eq 0 ] || reason="${reason:+$reason, }memtester exit $rc_m"
    if [ -z "$reason" ]; then
        diag_result "Memory under load" PASS
    else
        diag_result "Memory under load" FAIL "$reason"
    fi
}
```

- [ ] **Step 4: Install the trap in `recore-diag`**

In `packaging/rebuild-recore/usr/bin/recore-diag`, after the three `. "$LIB/..."` lines, add:

```bash
# Whatever ends this script - a finished run, Ctrl-C, a dropped ssh session -
# ends every load with it.
trap 'diag_stop_loads' EXIT
trap 'exit 130' INT TERM HUP
```

Also add a stub `diag_stop_loads() { :; }` line at the end of the stub `memory.sh` created in `packaging/tests/diag-cli.bats` `setup` (replace `: >"$DIAG_LIB/memory.sh"` with `echo 'diag_stop_loads() { :; }' >"$DIAG_LIB/memory.sh"`), so those tests keep working with the trap.

- [ ] **Step 5: Run all tests**

Run: `bats packaging/tests/`
Expected: every test passes, including the five in `diag-memory.bats`.

- [ ] **Step 6: Commit**

```bash
git add packaging/rebuild-recore/usr/lib/rebuild/diag/memory.sh packaging/rebuild-recore/usr/bin/recore-diag packaging/tests/
git -c user.email=elias@iagent.no commit -m "recore-diag: memory under GPU and eMMC load, bounded loads (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The GPU load helper

**Files:**
- Create: `packaging/rebuild-recore/usr/lib/rebuild/diag-gpu-load.py` (mode 755)

**Interfaces:**
- Produces: `diag-gpu-load.py [--seconds N] [--size N]`. Its first line on stdout is either `rendering on <GL_RENDERER> ...` or `not running: <reason>` (exit 1). It then runs until the time is up or it is killed. Task 4 prints that first line after "GPU load: ".

- [ ] **Step 1: Write the helper**

```python
#!/usr/bin/env python3
"""Load the Recore's GPU (Mali-400, lima) for recore-diag's memory test (#104).

Renders large textured quads into an offscreen framebuffer in a loop, with no
display and no compositor: EGL on Mesa's surfaceless platform, called through
ctypes so nothing has to be compiled. What matters is the DRAM traffic: the
A6 DRAM fault (DQ10) shows only while the GPU loads memory.

    diag-gpu-load.py --seconds 1800

The first line says what it is rendering on, or why it is not running.
"""
import argparse
import ctypes
import os
import random
import sys
import time

EGL_PLATFORM_SURFACELESS_MESA = 0x31DD
EGL_NONE = 0x3038
EGL_SURFACE_TYPE = 0x3033
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES2_BIT = 0x0004
EGL_CONTEXT_CLIENT_VERSION = 0x3098
EGL_OPENGL_ES_API = 0x30A0

GL_TEXTURE_2D = 0x0DE1
GL_TEXTURE0 = 0x84C0
GL_RGBA = 0x1908
GL_UNSIGNED_BYTE = 0x1401
GL_TEXTURE_MIN_FILTER = 0x2801
GL_TEXTURE_MAG_FILTER = 0x2800
GL_LINEAR = 0x2601
GL_FRAMEBUFFER = 0x8D40
GL_COLOR_ATTACHMENT0 = 0x8CE0
GL_FRAMEBUFFER_COMPLETE = 0x8CD5
GL_VERTEX_SHADER = 0x8B31
GL_FRAGMENT_SHADER = 0x8B30
GL_COMPILE_STATUS = 0x8B81
GL_LINK_STATUS = 0x8B82
GL_ARRAY_BUFFER = 0x8892
GL_STATIC_DRAW = 0x88E4
GL_FLOAT = 0x1406
GL_TRIANGLE_STRIP = 0x0005
GL_RENDERER = 0x1F01

SOURCE = 2048    # source texture, 16 MB: far larger than the GPU's caches

VS = b"""
attribute vec2 p;
varying vec2 uv;
uniform float o;
void main() { uv = p * 0.5 + 0.5 + vec2(o); gl_Position = vec4(p, 0.0, 1.0); }
"""
# Three scattered samples per pixel: mostly cache misses, so mostly DRAM reads.
FS = b"""
precision mediump float;
varying vec2 uv;
uniform sampler2D t;
void main() { gl_FragColor = texture2D(t, uv) + texture2D(t, uv * 1.37) + texture2D(t, uv * 0.73); }
"""


def fail(msg):
    print(f"not running: {msg}", flush=True)
    sys.exit(1)


def ints(*v):
    return (ctypes.c_int * len(v))(*v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=1800)
    ap.add_argument("--size", type=int, default=1024)
    a = ap.parse_args()

    try:
        egl = ctypes.CDLL("libEGL.so.1")
        gl = ctypes.CDLL("libGLESv2.so.2")
    except OSError as e:
        fail(f"no EGL/GLES libraries ({e})")
    vp = ctypes.c_void_p
    egl.eglGetPlatformDisplay.restype = vp
    egl.eglGetPlatformDisplay.argtypes = [ctypes.c_uint, vp, vp]
    egl.eglInitialize.argtypes = [vp, vp, vp]
    egl.eglBindAPI.argtypes = [ctypes.c_uint]
    egl.eglChooseConfig.argtypes = [vp, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(vp), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    egl.eglCreateContext.restype = vp
    egl.eglCreateContext.argtypes = [vp, vp, vp, ctypes.POINTER(ctypes.c_int)]
    egl.eglMakeCurrent.argtypes = [vp, vp, vp, vp]
    gl.glGetString.restype = ctypes.c_char_p
    gl.glUniform1f.argtypes = [ctypes.c_int, ctypes.c_float]
    gl.glGetUniformLocation.argtypes = [ctypes.c_uint, ctypes.c_char_p]
    gl.glGetAttribLocation.argtypes = [ctypes.c_uint, ctypes.c_char_p]
    gl.glVertexAttribPointer.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_uint, ctypes.c_ubyte, ctypes.c_int, vp]
    gl.glBufferData.argtypes = [ctypes.c_uint, ctypes.c_ssize_t, vp, ctypes.c_uint]
    gl.glTexImage2D.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, vp]

    dpy = egl.eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, None, None)
    if not dpy or not egl.eglInitialize(dpy, None, None):
        fail("no EGL surfaceless display (no GPU driver or render node?)")
    egl.eglBindAPI(EGL_OPENGL_ES_API)
    cfg, n = vp(), ctypes.c_int()
    if not egl.eglChooseConfig(dpy, ints(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, 0, EGL_NONE),
                               ctypes.byref(cfg), 1, ctypes.byref(n)) or n.value < 1:
        fail("no GLES2 EGL config")
    ctx = egl.eglCreateContext(dpy, cfg, None, ints(EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE))
    if not ctx or not egl.eglMakeCurrent(dpy, None, None, ctx):
        fail("no GLES2 context")

    def shader(kind, src):
        s = gl.glCreateShader(kind)
        p = ctypes.c_char_p(src)
        gl.glShaderSource(s, 1, ctypes.byref(p), None)
        gl.glCompileShader(s)
        ok = ctypes.c_int()
        gl.glGetShaderiv(s, GL_COMPILE_STATUS, ctypes.byref(ok))
        if not ok.value:
            fail("shader did not compile")
        return s

    prog = gl.glCreateProgram()
    gl.glAttachShader(prog, shader(GL_VERTEX_SHADER, VS))
    gl.glAttachShader(prog, shader(GL_FRAGMENT_SHADER, FS))
    gl.glLinkProgram(prog)
    ok = ctypes.c_int()
    gl.glGetProgramiv(prog, GL_LINK_STATUS, ctypes.byref(ok))
    if not ok.value:
        fail("program did not link")
    gl.glUseProgram(prog)

    src_tex = ctypes.c_uint()
    gl.glGenTextures(1, ctypes.byref(src_tex))
    gl.glActiveTexture(GL_TEXTURE0)
    gl.glBindTexture(GL_TEXTURE_2D, src_tex)
    data = os.urandom(SOURCE * SOURCE * 4)
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, SOURCE, SOURCE, 0, GL_RGBA, GL_UNSIGNED_BYTE, data)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    gl.glUniform1i(gl.glGetUniformLocation(prog, b"t"), 0)

    dst_tex, fbo = ctypes.c_uint(), ctypes.c_uint()
    gl.glGenTextures(1, ctypes.byref(dst_tex))
    gl.glBindTexture(GL_TEXTURE_2D, dst_tex)
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, a.size, a.size, 0, GL_RGBA, GL_UNSIGNED_BYTE, None)
    gl.glGenFramebuffers(1, ctypes.byref(fbo))
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst_tex, 0)
    if gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
        fail("offscreen framebuffer incomplete")
    gl.glBindTexture(GL_TEXTURE_2D, src_tex)
    gl.glViewport(0, 0, a.size, a.size)

    quad = (ctypes.c_float * 8)(-1, -1, 1, -1, -1, 1, 1, 1)
    vbo = ctypes.c_uint()
    gl.glGenBuffers(1, ctypes.byref(vbo))
    gl.glBindBuffer(GL_ARRAY_BUFFER, vbo)
    gl.glBufferData(GL_ARRAY_BUFFER, ctypes.sizeof(quad), quad, GL_STATIC_DRAW)
    loc = gl.glGetAttribLocation(prog, b"p")
    gl.glEnableVertexAttribArray(loc)
    gl.glVertexAttribPointer(loc, 2, GL_FLOAT, 0, 0, None)
    off = gl.glGetUniformLocation(prog, b"o")

    renderer = gl.glGetString(GL_RENDERER).decode()
    print(f"rendering on {renderer} ({a.size}x{a.size} target, {SOURCE}x{SOURCE} source)", flush=True)

    end, frames = time.monotonic() + a.seconds, 0
    while time.monotonic() < end:
        for _ in range(20):
            gl.glUniform1f(off, random.random())
            gl.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
        gl.glFinish()
        frames += 20
    print(f"{frames} frames", flush=True)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify it fails cleanly where there is no GPU**

Run on this laptop or any machine without `libEGL` or with no surfaceless driver:
`python3 packaging/rebuild-recore/usr/lib/rebuild/diag-gpu-load.py --seconds 3; echo "exit $?"`
Expected: the first line is either `rendering on ...` (a desktop with Mesa; it then exits after 3 s with `N frames`) or `not running: ...` with `exit 1`. Never a Python traceback.

- [ ] **Step 3: Verify it loads the Mali on a Rebuild A6**

Copy it to the A6 cell (192.168.32.109; get the current address from Recore-CI `cells`) and run, counting the GPU's interrupts before and after:

```bash
sshpass -p rebuildtest scp packaging/rebuild-recore/usr/lib/rebuild/diag-gpu-load.py debian@<a6-ip>:/tmp/
sshpass -p rebuildtest ssh debian@<a6-ip> 'grep -E "gp|pp0" /proc/interrupts; python3 /tmp/diag-gpu-load.py --seconds 20; grep -E "gp|pp0" /proc/interrupts'
```

Expected: `rendering on Mali400 (1024x1024 target, 2048x2048 source)`, then after 20 s `N frames` with N in the hundreds or more. The `gp` and `pp0` interrupt counts grow by at least N.

- [ ] **Step 4: Commit**

```bash
chmod 755 packaging/rebuild-recore/usr/lib/rebuild/diag-gpu-load.py
git add packaging/rebuild-recore/usr/lib/rebuild/diag-gpu-load.py
git -c user.email=elias@iagent.no commit -m "recore-diag: load the Mali without a display, for the memory test (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Packaging, and the checks on hardware

**Files:**
- Modify: `packaging/debian/control` (rebuild-recore Depends)

**Interfaces:**
- Consumes: Tasks 1-5, installed by `rebuild-recore`.

- [ ] **Step 1: Add the dependencies**

In `packaging/debian/control`, change the `rebuild-recore` stanza's Depends line from

```
Depends: ${misc:Depends}, dnsmasq-base, network-manager, udev
```

to

```
Depends: ${misc:Depends}, dnsmasq-base, network-manager, udev,
 memtester, mmc-utils, python3, stressapptest
```

- [ ] **Step 2: Build, and check what the package installs**

Run:
```bash
packaging/build-debs "$TMPDIR/debs" v1.1.0-99-gdiag000 >/dev/null
dpkg-deb -c "$TMPDIR"/debs/rebuild-recore_*_all.deb | grep -E 'recore-diag|/diag/|diag-gpu'
dpkg-deb -f "$TMPDIR"/debs/rebuild-recore_*_all.deb Depends
```
Expected: `usr/bin/recore-diag` (rwxr-xr-x), `usr/lib/rebuild/diag/{report,sections,memory}.sh`, `usr/lib/rebuild/diag-gpu-load.py` (rwxr-xr-x), and Depends listing `memtester, mmc-utils, python3, stressapptest`.

- [ ] **Step 3: Commit and push the branch**

```bash
git add packaging/debian/control
git -c user.email=elias@iagent.no commit -m "rebuild-recore: depend on the tools recore-diag runs (#104)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin recore-diag
```

- [ ] **Step 4: Install on the cells through the upgrade test**

With the Recore-CI MCP tool `upgrade_test(cell, ref="recore-diag")`, or `POST /api/cell/<cell>/upgrade-test {"ref":"recore-diag"}`, on `a5`, `a6`, `a8` and `voron`. Wait for each with `run_wait`.
Expected: each run ends `PASS: <cell> updated to 1.1.0+N.g<sha>, rebooted, and passed its cell tests`.

- [ ] **Step 5: Quick on every cell**

On each of a5, a6, a8 and voron: `sudo recore-diag`.
Expected: each report has the seven sections and a summary. Every RESULT is PASS, or a SKIPPED or FAIL whose reason is true of that board, for example Kernel warnings FAIL on a board with a real `-110`. Exit status 0, or 1 only for such a real finding. Paste each summary into the PR description.

- [ ] **Step 6: Extended on the Kossel: must catch the known fault**

1. The Kossel runs Reflash now. Install the current Rebuild image on it with the Recore-CI `test_image` tool, then the `recore-diag` packages with `upgrade_test(cell="kossel-a6", ref="recore-diag")`.
2. Run `sudo recore-diag --extended --yes` on it.
3. **Expected:** `RESULT Memory under load: FAIL ...`, with miscompares in the stressapptest or memtester output.
4. **If it passes,** the load is not doing what it should. Check that the GPU line said `rendering on Mali400` and that the `gp`/`pp0` interrupts grew during the run (Task 5, step 3) before going further.

- [ ] **Step 7: Extended on the bare A6 (0288)**

Run `sudo recore-diag --extended --yes` on `a6` and record the Memory under load result.
- **PASS** points to a defect in Kossel unit 0256.
- **FAIL on the same kind of bit** points to an A6 design issue.

Post the result to #104 and #112.

- [ ] **Step 8: A crash halfway, on the Voron**

1. Start `sudo recore-diag --extended --yes` on the Voron.
2. About 5 minutes in, during Memory under load, trigger a panic from a second session: `echo c | sudo tee /proc/sysrq-trigger`. The Voron reboots by itself with `recovery-107`, or use its mains plug.
3. After it is back, check:
   - `sudo recore-diag --last` ends with `=== Memory under load ===` followed by temperature lines and no summary;
   - `sudo recore-diag` starts with `The previous run (...) ended during: Memory under load`.

- [ ] **Step 9: Open the PR**

Open a PR from `recore-diag` to main with the spec link, the four Quick summaries, the Kossel and A6 Extended results, and the crash test result. Merge when the user says so.
