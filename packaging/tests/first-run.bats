#!/usr/bin/env bats

# rebuild-first-run and flash-stm32 run twice on a freshly flashed printer:
# under Reflash at install time, and on the first boot (#130). Whichever comes
# second must find the work done and leave the hardware alone.

PKG="$BATS_TEST_DIRNAME/.."

setup() {
    T="$(mktemp -d)"
    export CALLS="$T/calls"
    : > "$CALLS"
    mkdir -p "$T/shims" "$T/bin" "$T/firmware"
    PATH="$T/shims:$PATH"
    unset REFLASH_INTERFACE REFLASH_VERSION FORCE
}

teardown() { rm -rf "$T"; }

# shim NAME [EXIT] - records its argv, prints nothing.
shim() {
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\nexit %s\n' "$1" "${2:-0}" > "$T/shims/$1"
    chmod +x "$T/shims/$1"
}

# --- rebuild-first-run ----------------------------------------------------

first_run_env() {
    export REBUILD_FIRST_RUN_BIN="$T/bin" REBUILD_FIRST_RUN_LOG="$T/log/first-run.log"
    for c in flash-stm32 flash-rp2040 rebuild-firmware; do
        printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\necho "%s ran"\nexit ${%s_RC:-0}\n' \
            "$c" "$c" "$(echo "$c" | tr -- '-' '_')" > "$T/bin/$c"
        chmod +x "$T/bin/$c"
    done
    shim systemctl
}

@test "first-run on the first boot: every step, references only if missing, then disables itself" {
    first_run_env
    run bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run"
    [ "$status" -eq 0 ]
    grep -qx "flash-stm32 " "$CALLS"
    grep -qx "flash-rp2040 " "$CALLS"
    grep -qx "rebuild-firmware reference --missing" "$CALLS"
    grep -qx "systemctl disable rebuild-first-run.service" "$CALLS"
    grep -q -- "--First run: first boot--" "$T/log/first-run.log"
}

@test "first-run on the first boot: a failed STM32 flash still fails the run" {
    first_run_env
    flash_stm32_RC=1 run bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run"
    [ "$status" -ne 0 ]
    ! grep -q "systemctl disable" "$CALLS"
    grep -q "First run FAILED" "$T/log/first-run.log"
}

@test "first-run under Reflash: does the steps, touches no systemd, fails nothing" {
    first_run_env
    export REFLASH_INTERFACE=1 REFLASH_VERSION=v1.2.0
    flash_stm32_RC=1 run bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run" prepare
    [ "$status" -eq 0 ]
    grep -qx "flash-stm32 " "$CALLS"
    grep -qx "rebuild-firmware reference --missing" "$CALLS"
    ! grep -q "^systemctl" "$CALLS"
    grep -q "flash-stm32 exited non-zero - continuing, the first boot tries again" "$T/log/first-run.log"
    grep -q "done at install time; the first boot checks it" "$T/log/first-run.log"
}

@test "first-run under Reflash: configure is not ours" {
    first_run_env
    export REFLASH_INTERFACE=1
    run bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run" configure
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

@test "first-run: install time and first boot both leave their part of the log" {
    first_run_env
    REFLASH_INTERFACE=1 REFLASH_VERSION=v1.2.0 bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run" prepare
    bash "$PKG/rebuild-printer/usr/bin/rebuild-first-run"
    grep -q "First run: Reflash v1.2.0, at install time" "$T/log/first-run.log"
    grep -q "First run: first boot" "$T/log/first-run.log"
}

# --- flash-stm32 ----------------------------------------------------------

stm32_env() {
    export REBUILD_FIRMWARE_DIR="$T/firmware"
    echo "build one" > "$T/firmware/stm32f031-32k.bin"
    echo "the other" > "$T/firmware/stm32f031-16k.bin"
    for c in systemctl gpioset gpioget pkill; do shim "$c"; done
    printf '#!/bin/bash\necho a8\n' > "$T/shims/get-recore-revision"
    chmod +x "$T/shims/get-recore-revision"
    # The flash size read (-r FILE -S 0x1FFFF7CC:2) answers 32 KB; a write is
    # only recorded.
    cat > "$T/shims/stm32flash" <<'EOF'
#!/bin/bash
echo "stm32flash $*" >> "$CALLS"
[ "$1" = -r ] && printf '\x20\x00' > "$2"
exit 0
EOF
    chmod +x "$T/shims/stm32flash"
}

@test "flash-stm32: flashes, and remembers what it wrote" {
    stm32_env
    run bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    [ "$status" -eq 0 ]
    grep -q "^stm32flash -w $T/firmware/stm32f031-32k.bin" "$CALLS"
    grep -qx "systemctl stop klipper" "$CALLS"
    grep -qx "systemctl restart klipper" "$CALLS"
    [ "$(cat "$T/firmware/stm32.flashed")" = "stm32f031-32k $(sha256sum < "$T/firmware/stm32f031-32k.bin" | cut -d' ' -f1)" ]
}

@test "flash-stm32: the second run finds it done and does not touch the chip" {
    stm32_env
    bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    : > "$CALLS"
    run bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already has stm32f031-32k"* ]]
    [ ! -s "$CALLS" ]
}

@test "flash-stm32: a rebuilt firmware is flashed again, and so is everything with FORCE" {
    stm32_env
    bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    echo "build two" > "$T/firmware/stm32f031-32k.bin"
    : > "$CALLS"
    run bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    grep -q "^stm32flash -w" "$CALLS"

    : > "$CALLS"
    FORCE=1 run bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    grep -q "^stm32flash -w" "$CALLS"
}

@test "flash-stm32 under Reflash: no systemd in the chroot, no Klipper to stop" {
    stm32_env
    REFLASH_INTERFACE=1 run bash "$PKG/rebuild-printer/usr/bin/flash-stm32"
    [ "$status" -eq 0 ]
    grep -q "^stm32flash -w" "$CALLS"
    ! grep -q "^systemctl" "$CALLS"
}
