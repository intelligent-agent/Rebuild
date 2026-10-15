#!/usr/bin/env bats

# get-serial-number, get-recore-revision and get-recore-config read the board's
# config from the eMMC boot partition. They must mount it by offset, as Reflash
# does, because some boards have no partition table and so no p1 to mount (#165).

PKG="$BATS_TEST_DIRNAME/.."
BIN="$PKG/rebuild-recore/usr/bin"

setup() {
    T="$(mktemp -d)"
    export CALLS="$T/calls"
    : > "$CALLS"
    mkdir -p "$T/shims"
    export REBUILD_LIB="$PKG/rebuild-recore/usr/lib/rebuild"
    export REBUILD_CONFIG_DEV="$T/boot0" REBUILD_CONFIG_MNT="$T/mnt"
    PATH="$T/shims:$PATH"
    unset REFLASH_INTERFACE REFLASH_REVISION
    # mount fills the mount point the way the real one would.
    cat > "$T/shims/mount" <<SHIM
#!/bin/bash
echo "mount \$*" >> "$CALLS"
printf '0481\n' > "$T/mnt/serial_number"
printf '{ "Revision": "A8" }\n' > "$T/mnt/recore.json"
SHIM
    printf '#!/bin/bash\necho "umount $*" >> "%s"\n' "$CALLS" > "$T/shims/umount"
    printf '#!/bin/bash\necho "losetup $*" >> "%s"\nexit 1\n' "$CALLS" > "$T/shims/losetup"
    chmod +x "$T/shims/"*
}

teardown() { rm -rf "$T"; }

@test "get-serial-number mounts by offset and prints the serial" {
    run bash "$BIN/get-serial-number"
    [ "$status" -eq 0 ]
    [ "$output" = "0481" ]
    grep -q "mount -o ro,loop,offset=17408 $T/boot0 $T/mnt" "$CALLS"
    ! grep -q '^losetup' "$CALLS"
}

@test "get-recore-revision prints the lowercased revision" {
    run bash "$BIN/get-recore-revision"
    [ "$status" -eq 0 ]
    [ "$output" = "a8" ]
    ! grep -q '^losetup' "$CALLS"
}

@test "get-recore-config prints the config json" {
    run bash "$BIN/get-recore-config"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"Revision": "A8"'* ]]
}

@test "the config is unmounted afterwards" {
    run bash "$BIN/get-serial-number"
    [ "$(tail -1 "$CALLS")" = "umount $T/mnt" ]
}

@test "a failed mount fails the script and says why" {
    printf '#!/bin/bash\necho "mount: no such device" >&2\nexit 32\n' > "$T/shims/mount"
    run bash "$BIN/get-serial-number"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such device"* ]]
}

@test "get-recore-revision uses the revision Reflash gives it" {
    REFLASH_INTERFACE=1 REFLASH_REVISION=a6 run bash "$BIN/get-recore-revision"
    [ "$output" = "a6" ]
    [ ! -s "$CALLS" ]
}
