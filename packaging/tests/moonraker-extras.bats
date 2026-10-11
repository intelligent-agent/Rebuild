#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../rebuild-printer/usr/lib/rebuild/moonraker-extras"
setup() {
    export MOONRAKER="$BATS_TEST_TMPDIR/moonraker" PRINTER_DATA="$BATS_TEST_TMPDIR/printer_data"
    export MOONRAKER_EXTRAS_SRC="$BATS_TEST_TMPDIR/extras"
    mkdir -p "$MOONRAKER/moonraker/components" "$PRINTER_DATA/config" "$MOONRAKER_EXTRAS_SRC"
    git -C "$MOONRAKER" init -q
    git -C "$MOONRAKER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    : >"$MOONRAKER_EXTRAS_SRC/klipper_firmware.py"
    : >"$MOONRAKER_EXTRAS_SRC/recore_sensors.py"
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

@test "voltage bridge is restored once without replacing user configuration" {
    "$SCRIPT"
    "$SCRIPT"
    [ -L "$MOONRAKER/moonraker/components/recore_sensors.py" ]
    [ "$(grep -cx '\[recore_sensors\]' "$PRINTER_DATA/config/moonraker.conf")" -eq 1 ]
    [ "$(grep -cx '/moonraker/components/recore_sensors.py' "$MOONRAKER/.git/info/exclude")" -eq 1 ]
    sed -i 's/name: Input voltage/name: My supply/' "$PRINTER_DATA/config/moonraker.conf"
    rm "$MOONRAKER/moonraker/components/recore_sensors.py"
    "$SCRIPT"
    grep -qx 'name: My supply' "$PRINTER_DATA/config/moonraker.conf"
    [ -L "$MOONRAKER/moonraker/components/recore_sensors.py" ]
}
@test "a user voltage module is preserved" {
    echo '# custom voltage module' >"$MOONRAKER/moonraker/components/recore_sensors.py"
    "$SCRIPT"
    [ ! -L "$MOONRAKER/moonraker/components/recore_sensors.py" ]
    grep -qx '# custom voltage module' "$MOONRAKER/moonraker/components/recore_sensors.py"
}
