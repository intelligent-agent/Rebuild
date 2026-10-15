#!/usr/bin/env bats

# rebuild-firmware refuses to build or flash while the printer might be printing.
# The OctoPrint image has no [virtual_sdcard], so print_stats and virtual_sdcard
# are empty there for as long as Klipper runs; that must not read as "printing".

SCRIPT="$BATS_TEST_DIRNAME/../rebuild-printer/usr/bin/rebuild-firmware"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    eval "$(sed -n '/^printing() {/,/^}/p' "$SCRIPT")"
}

reply() {   # reply JSON - what Moonraker answers
    printf '#!/bin/bash\nprintf %%s %q\n' "{\"result\":{\"status\":$1}}" > "$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

@test "an idle printer is not printing" {
    reply '{"webhooks":{"state":"ready"},"print_stats":{"state":"standby"},"virtual_sdcard":{"is_active":false},"idle_timeout":{"state":"Idle"}}'
    run printing
    [ "$status" -eq 1 ]
}

@test "the octoprint image, with no virtual sdcard, is not printing" {
    reply '{"webhooks":{"state":"ready"},"print_stats":{},"virtual_sdcard":{},"idle_timeout":{"state":"Idle"}}'
    run printing
    [ "$status" -eq 1 ]
}

@test "a print, a pause and a moving printer are printing" {
    reply '{"webhooks":{"state":"ready"},"print_stats":{"state":"printing"},"virtual_sdcard":{"is_active":true},"idle_timeout":{"state":"Printing"}}'
    run printing; [ "$status" -eq 0 ]
    reply '{"webhooks":{"state":"ready"},"print_stats":{"state":"paused"},"virtual_sdcard":{"is_active":false},"idle_timeout":{"state":"Idle"}}'
    run printing; [ "$status" -eq 0 ]
    reply '{"webhooks":{"state":"ready"},"print_stats":{},"virtual_sdcard":{},"idle_timeout":{"state":"Printing"}}'
    run printing; [ "$status" -eq 0 ]
}

@test "a printer that is not ready is unknown, so not safe" {
    reply '{"webhooks":{"state":"startup"},"print_stats":{},"virtual_sdcard":{},"idle_timeout":{}}'
    run printing; [ "$status" -eq 0 ]
    reply '{"webhooks":{"state":"ready"},"print_stats":{},"virtual_sdcard":{},"idle_timeout":{}}'
    run printing; [ "$status" -eq 0 ]
}

@test "no answer from Moonraker fails closed" {
    printf '#!/bin/bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/curl"; chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    run printing; [ "$status" -eq 0 ]
    printf '#!/bin/bash\nprintf not-json\n' > "$BATS_TEST_TMPDIR/bin/curl"
    run printing; [ "$status" -eq 0 ]
}
