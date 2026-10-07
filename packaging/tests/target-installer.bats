#!/usr/bin/env bats

# Rebuild's target-installer (Reflash target interface v1), run against a
# scratch root tree through REFLASH_TEST_ROOT, the way Reflash runs it
# chrooted into a freshly written image.

PKG="$BATS_TEST_DIRNAME/.."

setup() {
    R="$(mktemp -d)"
    export REFLASH_TEST_ROOT="$R"
    export REFLASH_INTERFACE=1 REFLASH_REVISION=a5 REFLASH_SERIAL=0132
    export REFLASH_DEVICE=/dev/mmcblk2 REFLASH_ROOT_DEV=/dev/mmcblk2p2 REFLASH_BOOT_DEV=/dev/mmcblk2p1

    mkdir -p "$R/etc/ssh" "$R/etc/default" "$R/root" "$R/boot/dtb/allwinner" \
        "$R/etc/xdg/weston" "$R/home/printer/printer_data/config" "$R/usr/lib/reflash" \
        "$R/usr/share/rebuild/klipper"
    cp "$PKG/rebuild-recore/usr/lib/reflash/target-installer" "$R/usr/lib/reflash/"
    cp -r "$PKG/rebuild-printer/usr/lib/reflash/target-installer.d" "$R/usr/lib/reflash/"
    cp -r "$PKG/rebuild-printer/usr/share/rebuild/klipper/config" "$R/usr/share/rebuild/klipper/"

    cat > "$R/etc/fstab" <<'EOF'
UUID=old-root / ext4 defaults,noatime,commit=120,errors=remount-ro 0 1
UUID=old-boot /boot ext4 defaults,commit=120 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
    printf 'verbosity=1\nrootdev=UUID=old-root\nextraargs=quiet selinux=0\n\nfdtfile=allwinner/sun50i-a64-recore.dtb\n' > "$R/boot/armbianEnv.txt"
    : > "$R/boot/dtb/allwinner/sun50i-a64-recore-a5.dtb"
    : > "$R/boot/dtb/allwinner/sun50i-a64-recore.dtb"
    echo OPENSSHD_REGENERATE_HOST_KEYS=true > "$R/etc/default/armbian-firstrun"
    echo baked > "$R/etc/ssh/ssh_host_ed25519_key"
    printf '[output]\nname=HDMI-A-1\ntransform=normal\n' > "$R/etc/xdg/weston/weston.ini"
    echo '[gcode_macro X]' > "$R/home/printer/printer_data/config/fluidd.cfg"

    SHIMS="$R/.shims"
    mkdir -p "$SHIMS"
    export CALLS="$R/.calls"
    cat > "$SHIMS/blkid" <<'EOF'
#!/bin/bash
case "${@: -1}" in */mmcblk2p2) echo new-root ;; */mmcblk2p1) echo new-boot ;; esac
EOF
    cat > "$SHIMS/ssh-keygen" <<'EOF'
#!/bin/bash
echo "ssh-keygen $*" >> "$CALLS"
EOF
    chmod +x "$SHIMS"/*
    PATH="$SHIMS:$PATH"
    INSTALLER="$R/usr/lib/reflash/target-installer"
}

teardown() { rm -rf "$R"; }

settings() {
    printf 'SETTINGS=1\nSSH_ENABLED=true\nSCREEN_ROTATION=%s\nWIFI_SSID=%s\nWIFI_PSK=%s\nFUTURE_KEY=x\n' "$@"
}

@test "prepare: boot references, device tree, keys and Klipper config for the revision" {
    run "$INSTALLER" prepare
    [ "$status" -eq 0 ]
    grep -qx 'UUID=new-root / ext4 defaults,noatime,commit=120,errors=remount-ro 0 1' "$R/etc/fstab"
    grep -qx 'UUID=new-boot /boot ext4 defaults,commit=120 0 2' "$R/etc/fstab"
    grep -qx 'rootdev=UUID=new-root' "$R/boot/armbianEnv.txt"
    grep -qx 'fdtfile=allwinner/sun50i-a64-recore-a5.dtb' "$R/boot/armbianEnv.txt"
    [ "$(readlink "$R/boot/dtb/allwinner/sun50i-a64-recore.dtb")" = sun50i-a64-recore-a5.dtb ]
    [ -f "$R/root/.no_rootfs_resize" ]
    grep -qx OPENSSHD_REGENERATE_HOST_KEYS=false "$R/etc/default/armbian-firstrun"
    [ ! -e "$R/etc/ssh/ssh_host_ed25519_key" ]
    grep -qx "ssh-keygen -A -f $R" "$CALLS"
    cmp <(grep -v '^\[include' "$R/home/printer/printer_data/config/printer.cfg" | grep -v '^$') \
        <(grep -v '^$' "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg")
    [ "$(grep -c '^\[include fluidd.cfg\]' "$R/home/printer/printer_data/config/printer.cfg")" = 1 ]
}

@test "prepare: running twice gives the same result" {
    "$INSTALLER" prepare
    cp "$R/boot/armbianEnv.txt" "$R/env.first"
    cp "$R/home/printer/printer_data/config/printer.cfg" "$R/cfg.first"
    run "$INSTALLER" prepare
    [ "$status" -eq 0 ]
    diff "$R/env.first" "$R/boot/armbianEnv.txt"
    diff "$R/cfg.first" "$R/home/printer/printer_data/config/printer.cfg"
    [ "$(grep -c '^fdtfile=' "$R/boot/armbianEnv.txt")" = 1 ]
}

@test "prepare: a revision with no device tree fails, it does not boot the generic tree" {
    REFLASH_REVISION=a9 run "$INSTALLER" prepare
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: this image has no device tree for Recore a9"* ]]
    ! grep -q 'recore-a9' "$R/boot/armbianEnv.txt"
}

@test "prepare: refuses an interface or revision it does not understand" {
    REFLASH_INTERFACE=2 run "$INSTALLER" prepare
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Reflash speaks target interface '2'"* ]]

    REFLASH_REVISION="a5;reboot" run "$INSTALLER" prepare
    [ "$status" -ne 0 ]
}

@test "prepare: a barebone image, without a printer, needs no Klipper config" {
    rm -r "$R/home/printer"
    run "$INSTALLER" prepare
    [ "$status" -eq 0 ]
}

@test "configure: settings file survives being sourced, whatever was typed" {
    pwned="$R/pwned"
    settings 270 "Bob's \"home\" net" "it's \$(touch $pwned) wifi" > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$R/etc/rebuild-settings")" = 600 ]
    out=$(bash -c '. "$1" && printf "%s|%s|%s|%s" "$SSH_ENABLED_ON_BOOT" "$EXTERNAL_SCREEN_ROTATION" "$WIFI_SSID" "$WIFI_PSK"' _ "$R/etc/rebuild-settings")
    [ "$out" = "true|270|Bob's \"home\" net|it's \$(touch $pwned) wifi" ]
    [ ! -e "$pwned" ]
    # The passphrase is never in the installer's output, which is Reflash's log.
    [[ "$output" != *"touch"* ]]
}

@test "configure: rotation reaches Weston, the console and the splash, once" {
    settings 270 net pass | "$INSTALLER" configure
    settings 270 net pass > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    grep -qx 'transform=rotate-90' "$R/etc/xdg/weston/weston.ini"
    grep -qx 'extraargs=quiet selinux=0 fbcon=rotate:3 video=HDMI-A-1:panel_orientation=left_side_up video=Unknown-1:panel_orientation=left_side_up' "$R/boot/armbianEnv.txt"

    settings 0 net pass | "$INSTALLER" configure
    grep -qx 'transform=normal' "$R/etc/xdg/weston/weston.ini"
    grep -qx 'extraargs=quiet selinux=0 fbcon=rotate:0 video=HDMI-A-1:panel_orientation=normal video=Unknown-1:panel_orientation=normal' "$R/boot/armbianEnv.txt"
}

@test "configure: never touches a printer.cfg the user may have edited" {
    echo "# mine" > "$R/home/printer/printer_data/config/printer.cfg"
    settings 0 net pass > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/home/printer/printer_data/config/printer.cfg")" = "# mine" ]
}

@test "configure: refuses settings it cannot apply" {
    settings 45 net pass > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: screen rotation '45'"* ]]

    printf 'SETTINGS=2\n' > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -ne 0 ]
}
