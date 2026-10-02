#!/usr/bin/env bats
# klipper-extras: Rebuild's Klipper modules linked in when the config names
# them, and kept out of Moonraker's "untracked source files" (#116, #115).

SCRIPT="$BATS_TEST_DIRNAME/../rebuild-printer/usr/lib/rebuild/klipper-extras"

setup() {
    export KLIPPER="$BATS_TEST_TMPDIR/klipper" PRINTER_DATA="$BATS_TEST_TMPDIR/printer_data"
    export KLIPPER_EXTRAS_SRC="$BATS_TEST_TMPDIR/extras"
    mkdir -p "$KLIPPER/klippy/extras" "$PRINTER_DATA/config" "$KLIPPER_EXTRAS_SRC"
    git -C "$KLIPPER" init -q
    git -C "$KLIPPER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf 'from . import tmc2130_a5\n' >"$KLIPPER_EXTRAS_SRC/tmc2209_a5.py"
    : >"$KLIPPER_EXTRAS_SRC/tmc2130_a5.py"
    : >"$KLIPPER_EXTRAS_SRC/recore_thermistor.py"
}

untracked() { git -C "$KLIPPER" status --porcelain --untracked-files=all | sed -n 's/^?? //p'; }

@test "a module the config names is linked, and is not untracked in git" {
    printf '[tmc2209_a5 stepper_x]\n' >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"
    [ -L "$KLIPPER/klippy/extras/tmc2209_a5.py" ]
    [ -L "$KLIPPER/klippy/extras/tmc2130_a5.py" ]
    [ -z "$(untracked)" ]
    grep -qx '/klippy/extras/tmc2209_a5.py' "$KLIPPER/.git/info/exclude"
}

@test "a module no longer named is unlinked and its exclude line removed" {
    printf '[tmc2209_a5 stepper_x]\n' >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"
    : >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"
    [ ! -e "$KLIPPER/klippy/extras/tmc2209_a5.py" ]
    ! grep -q 'tmc2209_a5' "$KLIPPER/.git/info/exclude"
}

@test "running twice adds each line once" {
    printf '[recore_thermistor t]\n' >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"; "$SCRIPT"
    [ "$(grep -cx '/klippy/extras/recore_thermistor.py' "$KLIPPER/.git/info/exclude")" -eq 1 ]
}

@test "the user's own file of the same name stays untracked and visible" {
    printf '[recore_thermistor t]\n' >"$PRINTER_DATA/config/printer.cfg"
    echo "# mine" >"$KLIPPER/klippy/extras/recore_thermistor.py"
    "$SCRIPT"
    [ ! -L "$KLIPPER/klippy/extras/recore_thermistor.py" ]
    [ "$(untracked)" = "klippy/extras/recore_thermistor.py" ]
}

@test "the user's own exclude lines are kept" {
    mkdir -p "$KLIPPER/.git/info"
    printf '# git ls-files --others --exclude-from=.git/info/exclude\n/my-notes.txt\n' >"$KLIPPER/.git/info/exclude"
    printf '[recore_thermistor t]\n' >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"
    : >"$PRINTER_DATA/config/printer.cfg"
    "$SCRIPT"
    grep -qx '/my-notes.txt' "$KLIPPER/.git/info/exclude"
}
