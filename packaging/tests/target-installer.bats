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
    mkdir -p "$R/usr/lib/rebuild"
    cp "$PKG/rebuild-recore/usr/lib/rebuild/wifi-client" "$PKG/rebuild-recore/usr/lib/rebuild/migrate-rebuild-settings" "$R/usr/lib/rebuild/"

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
    printf 'root:x:0:0::/root:/bin/bash\ndebian:x:1000:1000::/home/debian:/bin/bash\n' > "$R/etc/passwd"

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
    # chpasswd and chage record what they were asked; chpasswd also what it
    # read, which is where a password may go and nowhere else.
    cat > "$SHIMS/chpasswd" <<'EOF'
#!/bin/bash
echo "chpasswd $*" >> "$CALLS"
cat > "$CALLS.chpasswd"
EOF
    cat > "$SHIMS/chage" <<'EOF'
#!/bin/bash
echo "chage $*" >> "$CALLS"
EOF
    # systemctl --root=R enable|disable|is-enabled ssh.service, kept in a file.
    cat > "$SHIMS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
for a in "$@"; do case $a in
    enable) echo enabled > "$REFLASH_TEST_ROOT/.ssh" ;;
    disable) echo disabled > "$REFLASH_TEST_ROOT/.ssh" ;;
    is-enabled) [ "$(cat "$REFLASH_TEST_ROOT/.ssh" 2>/dev/null)" = enabled ]; exit ;;
esac; done
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

client() { cat "$R/etc/NetworkManager/system-connections/Client.nmconnection"; }

@test "configure: Wi-Fi goes into NetworkManager's Client profile, taken literally" {
    settings 270 "Bob's \"home\" net " "it's \$(touch x) wifi" > "$R/s"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$R/etc/NetworkManager/system-connections/Client.nmconnection")" = 600 ]
    client | grep -qx 'id=Client'
    client | grep -qx 'autoconnect=false'
    # The trailing space kept, as GLib key files need it written.
    client | grep -qxF 'ssid=Bob'"'"'s "home" net\s'
    client | grep -qxF 'psk=it'"'"'s $(touch x) wifi'
    [ "$("$R/usr/lib/rebuild/wifi-client" ssid)" = "Bob's \"home\" net " ]
    [ "$("$R/usr/lib/rebuild/wifi-client" psk)" = "it's \$(touch x) wifi" ]
    # Nothing else holds it, and the passphrase is never in the output.
    [ ! -e "$R/etc/rebuild-settings" ]
    [[ "$output" != *"touch"* ]]
}

@test "configure: SSH at boot is ssh.service enabled or disabled" {
    cfg SSH_ENABLED=true
    "$INSTALLER" configure < "$R/s"
    grep -qx "systemctl --root=$R enable ssh.service" "$CALLS"
    cfg SSH_ENABLED=false
    "$INSTALLER" configure < "$R/s"
    grep -qx "systemctl --root=$R disable ssh.service" "$CALLS"
}

@test "configure: an empty network name removes the profile, and the board starts its hotspot" {
    cfg "WIFI_SSID=home" "WIFI_PSK=secret1"
    "$INSTALLER" configure < "$R/s"
    cfg "WIFI_SSID="
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    [ ! -e "$R/etc/NetworkManager/system-connections/Client.nmconnection" ]
}

@test "configure: a new passphrase alone keeps the network, and the profile's identity" {
    cfg "WIFI_SSID=home" "WIFI_PSK=secret1"
    "$INSTALLER" configure < "$R/s"
    uuid=$(client | grep ^uuid=)
    cfg "WIFI_PSK=secret2"
    "$INSTALLER" configure < "$R/s"
    client | grep -qx 'ssid=home'
    client | grep -qx 'psk=secret2'
    [ "$(client | grep ^uuid=)" = "$uuid" ]
}

@test "configure: an old /etc/rebuild-settings is removed - it held the passphrase twice" {
    printf "WIFI_PSK='old'\n" > "$R/etc/rebuild-settings"
    cfg SCREEN_ROTATION=0
    "$INSTALLER" configure < "$R/s"
    [ ! -e "$R/etc/rebuild-settings" ]
}

@test "migrate: an older Reflash's settings file becomes the Client profile and ssh.service, once" {
    # As Reflash v1.1.x writes it: shell-quoted (Reflash#157).
    cat > "$R/etc/rebuild-settings" <<'EOF'
SSH_ENABLED_ON_BOOT=true
SSH_TIMEOUT=60
WIFI_SSID='Bob'\''s net'
WIFI_PSK='p$ss'
EOF
    WIFI_CLIENT="$R/usr/lib/rebuild/wifi-client" run bash "$R/usr/lib/rebuild/migrate-rebuild-settings"
    [ "$status" -eq 0 ]
    [ "$("$R/usr/lib/rebuild/wifi-client" ssid)" = "Bob's net" ]
    [ "$("$R/usr/lib/rebuild/wifi-client" psk)" = 'p$ss' ]
    grep -qx "systemctl --root=$R enable ssh.service" "$CALLS"
    [ ! -e "$R/etc/rebuild-settings" ]
}

@test "migrate: a board that already joins a network keeps it" {
    printf 'mine\nkept\n' | "$R/usr/lib/rebuild/wifi-client" set
    printf "SSH_ENABLED_ON_BOOT=false\nWIFI_SSID='theirs'\nWIFI_PSK='x'\n" > "$R/etc/rebuild-settings"
    WIFI_CLIENT="$R/usr/lib/rebuild/wifi-client" run bash "$R/usr/lib/rebuild/migrate-rebuild-settings"
    [ "$status" -eq 0 ]
    [ "$("$R/usr/lib/rebuild/wifi-client" ssid)" = mine ]
    grep -qx "systemctl --root=$R disable ssh.service" "$CALLS"
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

cfg() { printf '%s\n' SETTINGS=1 "$@" > "$R/s"; }

@test "configure: only the settings given change, the rest stay as they were" {
    cfg SSH_ENABLED=true SCREEN_ROTATION=270 "WIFI_SSID=home" "WIFI_PSK=secret1"
    "$INSTALLER" configure < "$R/s"
    cfg SCREEN_ROTATION=90
    : > "$CALLS"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    client | grep -qx 'ssid=home'
    client | grep -qx 'psk=secret1'
    ! grep -q '^systemctl' "$CALLS"
    grep -qx 'transform=rotate-270' "$R/etc/xdg/weston/weston.ini"
    grep -q 'fbcon=rotate:1 ' "$R/boot/armbianEnv.txt"
}

@test "configure: without a rotation key the screen is left alone" {
    cfg "WIFI_SSID=home"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    grep -qx 'transform=normal' "$R/etc/xdg/weston/weston.ini"
    ! grep -q 'fbcon=rotate' "$R/boot/armbianEnv.txt"
}

@test "configure: LOGIN_PASSWORD sets debian's password, without logging it, and ends the forced change" {
    cfg "LOGIN_PASSWORD=correct horse"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    grep -qx "chpasswd -R $R" "$CALLS"
    [ "$(cat "$CALLS.chpasswd")" = "debian:correct horse" ]
    grep -qE "^chage -R $R -d 20[0-9]{2}-[0-9]{2}-[0-9]{2} debian$" "$CALLS"
    [[ "$output" == *"login password set for debian"* ]]
    [[ "$output" != *"horse"* ]]
    ! grep -rq horse "$R/etc/NetworkManager" 2>/dev/null
}

@test "configure: barebone has only root, so that is whose password it is" {
    sed -i '/^debian:/d' "$R/etc/passwd"
    cfg "LOGIN_PASSWORD=correct horse"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS.chpasswd")" = "root:correct horse" ]
}

@test "configure: a password the image's rules refuse fails, and nothing is set" {
    cfg "LOGIN_PASSWORD=abc"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: the password is too short"* ]]

    cfg "LOGIN_PASSWORD=abcddcba"
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: the password is a palindrome"* ]]
    ! grep -q chpasswd "$CALLS"
}

@test "configure: no LOGIN_PASSWORD, or an empty one, leaves the account alone" {
    cfg "LOGIN_PASSWORD="
    run "$INSTALLER" configure < "$R/s"
    [ "$status" -eq 0 ]
    ! grep -qE '^(chpasswd|chage)' "$CALLS"
}

@test "settings: the current choices, never the secrets" {
    cfg SSH_ENABLED=true SCREEN_ROTATION=270 "WIFI_SSID=Bob's net" "WIFI_PSK=secret1" "LOGIN_PASSWORD=correct horse"
    "$INSTALLER" configure < "$R/s"
    run "$INSTALLER" settings
    [ "$status" -eq 0 ]
    [ "$output" = $'SETTINGS=1\nSSH_ENABLED=true\nSCREEN_ROTATION=270\nWIFI_SSID=Bob\'s net' ]
}

@test "an action this image does not support exits 3" {
    run "$INSTALLER" teleport
    [ "$status" -eq 3 ]
}

@test "backup: the printer's configuration and database, not gcodes or logs" {
    d="$R/home/printer/printer_data"
    mkdir -p "$d/database" "$d/gcodes" "$d/logs"
    echo "[printer]" > "$d/config/printer.cfg"
    echo db > "$d/database/moonraker-sql.db"
    echo big > "$d/gcodes/benchy.gcode"
    echo log > "$d/config/klippy.log"
    "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    tar -tzf "$R/b.tgz" > "$R/list"
    grep -qx 'home/printer/printer_data/config/printer.cfg' "$R/list"
    grep -qx 'home/printer/printer_data/database/moonraker-sql.db' "$R/list"
    ! grep -q gcodes "$R/list"
    ! grep -q 'klippy.log' "$R/list"
}

# Reflash#184, #136: every backup says where it came from.
@test "backup: a manifest first, saying where the files came from" {
    echo "rebuild-fluidd-v1.2.0" > "$R/etc/rebuild-version"
    echo "[printer]" > "$R/home/printer/printer_data/config/printer.cfg"
    REFLASH_VERSION=v1.2.0 "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    [ "$(tar -tzf "$R/b.tgz" | head -1)" = rebuild-backup.manifest ]
    tar -xzOf "$R/b.tgz" rebuild-backup.manifest > "$R/m"
    grep -qx 'format=1' "$R/m"
    grep -qx 'rebuild_version=rebuild-fluidd-v1.2.0' "$R/m"
    grep -qx 'board_revision=a5' "$R/m"
    grep -qx 'board_serial=0132' "$R/m"
    grep -qx 'reflash_version=v1.2.0' "$R/m"
    grep -qx 'paths=home/printer/printer_data/config' "$R/m"
}

# Barebone has none of the files. tar refused an empty archive and the
# backup failed (exit 2); now it is the manifest alone.
@test "backup: a system with none of the files still makes a backup" {
    rm -rf "$R/home/printer"
    run "$INSTALLER" backup
    [ "$status" -eq 0 ]
    "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    [ "$(tar -tzf "$R/b.tgz")" = rebuild-backup.manifest ]
}

@test "restore: a backup with only its manifest is valid, with nothing to put back" {
    rm -rf "$R/home/printer"
    "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    run "$INSTALLER" restore < "$R/b.tgz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to restore"* ]]
}

@test "restore: puts the files back over a fresh install, and nothing outside them" {
    d="$R/home/printer/printer_data"
    echo "mine" > "$d/config/printer.cfg"
    "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    echo "stock" > "$d/config/printer.cfg"
    run "$INSTALLER" restore < "$R/b.tgz"
    [ "$status" -eq 0 ]
    [ "$(cat "$d/config/printer.cfg")" = mine ]

    # An archive that reaches for the rest of the system gets nowhere.
    mkdir -p "$R/evil/etc"
    echo "root::0:0" > "$R/evil/etc/shadow"
    tar -C "$R/evil" -czf "$R/evil.tgz" etc/shadow
    run "$INSTALLER" restore < "$R/evil.tgz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: this is not a Rebuild backup"* ]]
    [ ! -e "$R/etc/shadow" ]
}
