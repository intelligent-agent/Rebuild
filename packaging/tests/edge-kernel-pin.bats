#!/usr/bin/env bats

# Armbian's edge kernel has no simpledrm, so a board on it has no screen. Rebuild
# hosts its own build of it on feeds, and Armbian's package carries a higher
# version: without the apt preference, apt would offer Armbian's as an upgrade.

PIN="$BATS_TEST_DIRNAME/../rebuild-recore/etc/apt/preferences.d/rebuild-edge-kernel"

@test "the pin names the edge kernel and its device trees" {
    grep -qx 'Package: linux-image-edge-sunxi64 linux-dtb-edge-sunxi64' "$PIN"
}

@test "the pin prefers the feeds origin" {
    grep -qx 'Pin: origin feeds.iagent.no' "$PIN"
}

@test "the pin does not downgrade a board that has another edge kernel" {
    # Above 500 so feeds wins, at most 1000 so apt never goes down to it.
    prio=$(sed -n 's/^Pin-Priority: *//p' "$PIN")
    [ "$prio" -gt 500 ]
    [ "$prio" -le 1000 ]
}

@test "the pin is installed with the package" {
    grep -q 'rebuild-recore/etc ' "$BATS_TEST_DIRNAME/../debian/rebuild-recore.install"
}
