#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../rebuild-printer/usr/lib/rebuild/moonraker-extras"
setup() {
    export MOONRAKER="$BATS_TEST_TMPDIR/moonraker" PRINTER_DATA="$BATS_TEST_TMPDIR/printer_data"
    export MOONRAKER_EXTRAS_SRC="$BATS_TEST_TMPDIR/extras"
    mkdir -p "$MOONRAKER/moonraker/components" "$PRINTER_DATA/config" "$MOONRAKER_EXTRAS_SRC"
    git -C "$MOONRAKER" init -q
    git -C "$MOONRAKER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    : >"$MOONRAKER_EXTRAS_SRC/klipper_firmware.py"
    printf '[server]\n' >"$PRINTER_DATA/config/moonraker.conf"
    printf 'ssh\nrebuild-firmware\nKlipperScreen\n' >"$PRINTER_DATA/moonraker.asvc"
}
@test "restored config gets updater, hides service and keeps checkout clean" {
    "$SCRIPT"
    [ -L "$MOONRAKER/moonraker/components/klipper_firmware.py" ]
    [ -z "$(git -C "$MOONRAKER" status --porcelain)" ]
    grep -qx '\[klipper_firmware\]' "$PRINTER_DATA/config/moonraker.conf"
    ! grep -q rebuild-firmware "$PRINTER_DATA/moonraker.asvc"
    grep -qx ssh "$PRINTER_DATA/moonraker.asvc"
}
@test "repeated starts do not duplicate config or git exclusion" {
    "$SCRIPT"
    "$SCRIPT"
    [ "$(grep -cx '\[klipper_firmware\]' "$PRINTER_DATA/config/moonraker.conf")" -eq 1 ]
    [ "$(grep -cx '/moonraker/components/klipper_firmware.py' "$MOONRAKER/.git/info/exclude")" -eq 1 ]
}
@test "checkout update removing a link is repaired on next start" {
    "$SCRIPT"
    rm "$MOONRAKER/moonraker/components/klipper_firmware.py"
    "$SCRIPT"
    [ -L "$MOONRAKER/moonraker/components/klipper_firmware.py" ]
}
@test "a user provided module is preserved" {
    echo '# user module' >"$MOONRAKER/moonraker/components/klipper_firmware.py"
    "$SCRIPT"
    [ ! -L "$MOONRAKER/moonraker/components/klipper_firmware.py" ]
    grep -qx '# user module' "$MOONRAKER/moonraker/components/klipper_firmware.py"
}
@test "an empty instance uuid file is removed so Moonraker writes a new one" {
    : >"$PRINTER_DATA/.moonraker.uuid"
    "$SCRIPT"
    [ ! -e "$PRINTER_DATA/.moonraker.uuid" ]
}
@test "an instance uuid that has content is left alone" {
    printf '58621f2a419143829d6af4f17309c30e' >"$PRINTER_DATA/.moonraker.uuid"
    "$SCRIPT"
    [ "$(cat "$PRINTER_DATA/.moonraker.uuid")" = 58621f2a419143829d6af4f17309c30e ]
}
@test "no uuid file at all is fine" {
    "$SCRIPT"
    [ ! -e "$PRINTER_DATA/.moonraker.uuid" ]
}
@test "the empty uuid file goes even when the rest of the script has nothing to do" {
    rm "$PRINTER_DATA/config/moonraker.conf"
    : >"$PRINTER_DATA/.moonraker.uuid"
    "$SCRIPT"
    [ ! -e "$PRINTER_DATA/.moonraker.uuid" ]
}
