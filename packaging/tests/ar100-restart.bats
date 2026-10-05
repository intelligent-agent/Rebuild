#!/usr/bin/env bats

@test "all Recore templates explicitly select command reset for AR100" {
    for revision in a5 a6 a7 a8; do
        cfg="$BATS_TEST_DIRNAME/../rebuild-printer/usr/share/rebuild/klipper/config/generic-recore-$revision.cfg"
        block=$(awk '/^\[mcu ar100\]/{section=1;next} /^\[/{section=0} section' "$cfg")
        [[ "$block" == *"restart_method: command"* ]]
    done
}
