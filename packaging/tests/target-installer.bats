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
    mkdir -p "$R/usr/lib/rebuild" "$R/usr/bin"
    cp "$PKG/rebuild-printer/usr/bin/rebuild-reference" "$R/usr/bin/"
    cp "$PKG/rebuild-recore/usr/lib/rebuild/wifi-client" "$PKG/rebuild-recore/usr/lib/rebuild/migrate-rebuild-settings" "$PKG/rebuild-printer/usr/lib/rebuild/software" "$R/usr/lib/rebuild/"
    mkdir -p "$R/usr/share/rebuild/klipper/optional" "$R/home/printer/klipper/klippy/extras" "$R/usr/share/zoneinfo/Europe"
    cp "$PKG/rebuild-printer/usr/share/rebuild/klipper/optional/led_effect.py" "$R/usr/share/rebuild/klipper/optional/"
    : > "$R/usr/share/zoneinfo/Europe/Oslo"; : > "$R/usr/share/zoneinfo/Europe/Berlin"; mkdir -p "$R/usr/share/zoneinfo/Etc"; : > "$R/usr/share/zoneinfo/Etc/UTC"
    : > "$R/root/.not_logged_in_yet"

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
    [ "$(head -4 <<< "$output")" = $'SETTINGS=1\nSSH_ENABLED=true\nSCREEN_ROTATION=270\nWIFI_SSID=Bob\'s net' ]
    # What Reflash#198 added, in the order it is printed, still with no secret.
    [[ "$output" == *$'WIFI_COUNTRY=\nTIMEZONE=Etc/UTC\nWIFI_MODE=auto\nHOTSPOT_SSID='* ]]
    [[ "$output" != *secret1* && "$output" != *"correct horse"* ]]
}

@test "settings secrets: the Wi-Fi passphrase follows the name, and nothing else secret" {
    cfg SSH_ENABLED=true SCREEN_ROTATION=90 "WIFI_SSID=Bob's net" "WIFI_PSK=se=cret 1" "LOGIN_PASSWORD=correct horse"
    "$INSTALLER" configure < "$R/s"
    run --separate-stderr "$INSTALLER" settings secrets
    [ "$status" -eq 0 ]
    [ "$(head -4 <<< "$output")" = $'SETTINGS=1\nSSH_ENABLED=true\nSCREEN_ROTATION=90\nWIFI_SSID=Bob\'s net' ]
    [[ "$output" == *$'\nWIFI_PSK=se=cret 1'* ]]
    [[ "$output" != *"correct horse"* ]]
    # Not on stderr, where Reflash logs it.
    [[ "$stderr" != *"se=cret"* ]]
}

@test "settings secrets: no network, no passphrase line" {
    run "$INSTALLER" settings secrets
    [ "$status" -eq 0 ]
    [[ "$output" != *WIFI_PSK* ]]
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

@test "backup: the manifest names the Klipper version of the checkout" {
    git -C "$R/home/printer" init -q klipper
    git -C "$R/home/printer/klipper" -c user.email=t@t -c user.name=t commit -q --allow-empty -m k
    git -C "$R/home/printer/klipper" tag v0.13.0
    "$INSTALLER" backup > "$R/b.tgz" 2>/dev/null
    tar -xzOf "$R/b.tgz" rebuild-backup.manifest | grep -qx 'klipper_version=v0.13.0'
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

# Every test here sets REFLASH_TEST_ROOT, so none runs with R empty - which is
# what a board does. ${R:?} passed them all and failed every real restore with
# "R: parameter null or not set" (Reflash#184, on A5).
@test "nothing in the installer refuses an empty R" {
    ! grep -v '^[[:space:]]*#' "$INSTALLER" | grep -n '\${R:?}'
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

# The reference copy of this version's example config (#137), and what a backup
# leaves out so that a restore does not put an old copy over it.

REF="home/printer/printer_data/config/rebuild-reference"

@test "reference: the board's example and a README, next to the user's config" {
    run "$R/usr/bin/rebuild-reference"
    [ "$status" -eq 0 ]
    cmp "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg" "$R/$REF/generic-recore-a5.cfg"
    grep -q "generic-recore-a5.cfg" "$R/$REF/README"
    grep -q "Config_Changes.md" "$R/$REF/README"
    # Readable by whoever serves them: the README came out of mktemp as 600.
    [ "$(stat -c %a "$R/$REF/README")" = 644 ]
    [ "$(stat -c %a "$R/$REF/generic-recore-a5.cfg")" = 644 ]
    # Only this board's, and nothing of the user's touched.
    [ "$(ls "$R/$REF" | grep -c '^generic-recore')" -eq 1 ]
    [ ! -e "$R/home/printer/printer_data/config/printer.cfg" ]
}

@test "reference: written again when the example changes, and left alone when it does not" {
    "$R/usr/bin/rebuild-reference"
    run "$R/usr/bin/rebuild-reference"
    [[ "$output" != *wrote* ]]
    echo "# a newer example" >> "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg"
    run "$R/usr/bin/rebuild-reference"
    [[ "$output" == *"wrote generic-recore-a5.cfg"* ]]
    cmp "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg" "$R/$REF/generic-recore-a5.cfg"
}

@test "reference: another board's example, left from a config moved between boards, goes" {
    mkdir -p "$R/$REF"
    echo old > "$R/$REF/generic-recore-a8.cfg"
    "$R/usr/bin/rebuild-reference"
    [ ! -e "$R/$REF/generic-recore-a8.cfg" ]
    [ -e "$R/$REF/generic-recore-a5.cfg" ]
}

@test "reference: an unknown revision writes nothing and does not fail" {
    run env REFLASH_REVISION=z9 "$R/usr/bin/rebuild-reference"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no example config for Recore z9"* ]]
    [ ! -e "$R/$REF" ]
    run env REFLASH_REVISION= "$R/usr/bin/rebuild-reference"
    [ "$status" -eq 0 ]
    [ ! -e "$R/$REF" ]
}

@test "reference: a system with no config folder is left alone" {
    rm -rf "$R/home/printer/printer_data"
    run "$R/usr/bin/rebuild-reference"
    [ "$status" -eq 0 ]
    [ ! -e "$R/home/printer/printer_data" ]
}

@test "reference hook: on prepare and configure, not on anything else, and never failing" {
    hook="$R/usr/lib/reflash/target-installer.d/60-reference"
    run "$hook" settings
    [ "$status" -eq 0 ]
    [ ! -e "$R/$REF" ]
    run "$hook" prepare
    [ "$status" -eq 0 ]
    [ -e "$R/$REF/generic-recore-a5.cfg" ]
    rm -rf "$R/$REF"
    run "$hook" configure
    [ "$status" -eq 0 ]
    [ -e "$R/$REF/generic-recore-a5.cfg" ]
    # No writer on the image, say: the install goes on.
    rm "$R/usr/bin/rebuild-reference"
    run "$hook" configure
    [ "$status" -eq 0 ]
}

@test "backup: what Rebuild generates is not the user's, and stays out" {
    c="$R/home/printer/printer_data/config"
    mkdir -p "$c/firmware" "$c/$(basename "$REF")"
    echo mine > "$c/printer.cfg"
    echo conf > "$c/moonraker.conf"
    echo bkp > "$c/.moonraker.conf.bkp"
    echo "CONFIG_X=y" > "$c/firmware/stm32.config"
    echo "# all options" > "$c/firmware/stm32.reference"
    echo ref > "$c/rebuild-reference/generic-recore-a5.cfg"
    "$INSTALLER" backup > "$R/b.tgz"
    list=$(tar tzf "$R/b.tgz")
    [[ "$list" == *"config/printer.cfg"* ]]
    [[ "$list" == *"config/moonraker.conf"* ]]
    [[ "$list" == *"config/fluidd.cfg"* ]]
    # The user's own changes to the firmware stay; the generated reference does not.
    [[ "$list" == *"config/firmware/stm32.config"* ]]
    [[ "$list" != *"stm32.reference"* ]]
    [[ "$list" != *"rebuild-reference"* ]]
    [[ "$list" != *".moonraker.conf.bkp"* ]]
}

@test "restore: the reference config is written again after the config folder is replaced" {
    c="$R/home/printer/printer_data/config"
    echo mine > "$c/printer.cfg"
    "$INSTALLER" backup > "$R/b.tgz"
    rm -rf "$R/$REF"
    run "$INSTALLER" restore < "$R/b.tgz"
    [ "$status" -eq 0 ]
    [ "$(cat "$c/printer.cfg")" = mine ]
    cmp "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg" "$R/$REF/generic-recore-a5.cfg"
}

@test "restore: an older backup's generated files do not come back over the installed ones" {
    c="$R/home/printer/printer_data/config"
    mkdir -p "$R/old/home/printer/printer_data/config/rebuild-reference" "$R/old/home/printer/printer_data/config/firmware"
    o="$R/old/home/printer/printer_data/config"
    echo mine > "$o/printer.cfg"
    echo stale > "$o/rebuild-reference/generic-recore-a5.cfg"
    printf 'format=1\n' > "$R/old/rebuild-backup.manifest"
    tar czf "$R/old.tgz" -C "$R/old" rebuild-backup.manifest home
    "$INSTALLER" backup > /dev/null  # a system with its own files
    run "$INSTALLER" restore < "$R/old.tgz"
    [ "$status" -eq 0 ]
    [ "$(cat "$c/printer.cfg")" = mine ]
    cmp "$R/usr/share/rebuild/klipper/config/generic-recore-a5.cfg" "$R/$REF/generic-recore-a5.cfg"
}


# ---- Reflash#198: root password, country, timezone, Wi-Fi mode, software ----

give() { printf 'SETTINGS=1\n'; printf '%s\n' "$@"; }

@test "root password: set with chpasswd, and Armbian's first login is skipped" {
    run bash -c "printf 'SETTINGS=1\nROOT_PASSWORD=sekret-77\n' | '$INSTALLER' configure"
    [ "$status" -eq 0 ]
    grep -q '^chpasswd' "$CALLS"
    [ "$(cat "$CALLS.chpasswd")" = "root:sekret-77" ]
    grep -q '^chage .* root$' "$CALLS"
    [ ! -e "$R/root/.not_logged_in_yet" ]
    [[ $output != *sekret-77* ]]
}

@test "root password: too short is refused and nothing else changes" {
    run bash -c "printf 'SETTINGS=1\nROOT_PASSWORD=abc\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    [[ $output == *"too short"* ]]
    [ -e "$R/root/.not_logged_in_yet" ]
}

@test "nothing set: the first-login setup is left as it is" {
    run bash -c "printf 'SETTINGS=1\nSSH_ENABLED=true\nSCREEN_ROTATION=90\n' | '$INSTALLER' configure"
    [ "$status" -eq 0 ]
    [ -e "$R/root/.not_logged_in_yet" ]
}

@test "country: a kernel argument, replaced not repeated, and removed by an empty value" {
    give WIFI_COUNTRY=NO | "$INSTALLER" configure
    give WIFI_COUNTRY=SE | "$INSTALLER" configure
    [ "$(grep -o 'cfg80211.ieee80211_regdom=[A-Z]*' "$R/boot/armbianEnv.txt" | wc -l)" -eq 1 ]
    grep -q 'regdom=SE' "$R/boot/armbianEnv.txt"
    grep -q '^extraargs=quiet selinux=0 cfg80211' "$R/boot/armbianEnv.txt"
    [ ! -e "$R/root/.not_logged_in_yet" ]
    give WIFI_COUNTRY= | "$INSTALLER" configure
    ! grep -q regdom "$R/boot/armbianEnv.txt"
    grep -q '^extraargs=quiet selinux=0$' "$R/boot/armbianEnv.txt"
}

@test "country: rotation does not remove it and it does not remove rotation" {
    give WIFI_COUNTRY=NO SCREEN_ROTATION=90 | "$INSTALLER" configure
    give SCREEN_ROTATION=180 | "$INSTALLER" configure
    grep -q 'regdom=NO' "$R/boot/armbianEnv.txt"
    grep -q 'fbcon=rotate:2' "$R/boot/armbianEnv.txt"
}

@test "country: only two capital letters" {
    run bash -c "printf 'SETTINGS=1\nWIFI_COUNTRY=Norway\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    [[ $output == *"two-letter"* ]]
}

@test "timezone: set, read back, and put back to UTC by an empty value" {
    give TIMEZONE=Europe/Oslo | "$INSTALLER" configure
    [ "$(cat "$R/etc/timezone")" = Europe/Oslo ]
    [ "$(readlink "$R/etc/localtime")" = /usr/share/zoneinfo/Europe/Oslo ]
    run "$INSTALLER" settings
    [[ $output == *"TIMEZONE=Europe/Oslo"* ]]
    give TIMEZONE= | "$INSTALLER" configure
    [ "$(cat "$R/etc/timezone")" = Etc/UTC ]
}

@test "timezone: a name the image does not know, or a path trick, is refused" {
    run bash -c "printf 'SETTINGS=1\nTIMEZONE=Mars/Olympus\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    run bash -c "printf 'SETTINGS=1\nTIMEZONE=../../etc/passwd\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    [ ! -e "$R/etc/localtime" ]
}

@test "Wi-Fi mode and hotspot: kept for autohotspot, the password only for Reflash's start" {
    give WIFI_MODE=client HOTSPOT_SSID=Verkstedet HOTSPOT_PSK=hemmelig-1 | "$INSTALLER" configure
    [ "$(stat -c %a "$R/etc/default/autohotspot")" = 600 ]
    grep -q '^WIFI_MODE=client' "$R/etc/default/autohotspot"
    run "$INSTALLER" settings
    [[ $output == *"WIFI_MODE=client"* && $output == *"HOTSPOT_SSID=Verkstedet"* ]]
    [[ $output != *hemmelig-1* ]]
    run "$INSTALLER" settings secrets
    [[ $output == *"HOTSPOT_PSK=hemmelig-1"* ]]
}

@test "Wi-Fi mode: auto and empty values take it all back to the defaults" {
    give WIFI_MODE=ap HOTSPOT_SSID=Verkstedet HOTSPOT_PSK=hemmelig-1 | "$INSTALLER" configure
    give WIFI_MODE=auto HOTSPOT_SSID= HOTSPOT_PSK= | "$INSTALLER" configure
    [ ! -e "$R/etc/default/autohotspot" ]
    run "$INSTALLER" settings secrets
    [[ $output == *"WIFI_MODE=auto"* && $output != *HOTSPOT_PSK* ]]
}

@test "Wi-Fi mode: the log never holds the hotspot's password" {
    run bash -c "printf 'SETTINGS=1\nHOTSPOT_PSK=hemmelig-1\n' | '$INSTALLER' configure"
    [ "$status" -eq 0 ]
    [[ $output != *hemmelig-1* ]]
}

@test "Wi-Fi mode: a hotspot password that WPA would refuse is refused" {
    run bash -c "printf 'SETTINGS=1\nHOTSPOT_PSK=short\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    run bash -c "printf 'SETTINGS=1\nWIFI_MODE=both\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
}

@test "autohotspot: reads the mode and the hotspot's name and password" {
    grep -q 'etc/default/autohotspot' "$PKG/rebuild-recore/usr/bin/autohotspot"
    grep -q 'HOTSPOT_SSID' "$PKG/rebuild-recore/usr/bin/autohotspot"
    grep -q '"\$WIFI_MODE" = ap' "$PKG/rebuild-recore/usr/bin/autohotspot"
    bash -n "$PKG/rebuild-recore/usr/bin/autohotspot"
}

@test "software: listed, installed, read back and removed, as a link into Klipper" {
    run "$INSTALLER" settings
    [[ $output == *"SOFTWARE_LIST=led_effect"* && $output == *"SOFTWARE_led_effect=off"* && $output == *"SOFTWARE_led_effect_INFO=LED effects"* ]]
    give SOFTWARE_led_effect=on | "$INSTALLER" configure
    [ -L "$R/home/printer/klipper/klippy/extras/led_effect.py" ]
    run "$INSTALLER" settings
    [[ $output == *"SOFTWARE_led_effect=on"* ]]
    give SOFTWARE_led_effect=on | "$INSTALLER" configure
    give SOFTWARE_led_effect=off | "$INSTALLER" configure
    [ ! -e "$R/home/printer/klipper/klippy/extras/led_effect.py" ]
}

@test "software: a copy somebody else put there counts as installed and is left alone" {
    echo mine > "$R/home/printer/klipper/klippy/extras/led_effect.py"
    run "$INSTALLER" settings
    [[ $output == *"SOFTWARE_led_effect=on"* ]]
    give SOFTWARE_led_effect=off | "$INSTALLER" configure
    [ "$(cat "$R/home/printer/klipper/klippy/extras/led_effect.py")" = mine ]
}

@test "software: nothing is offered without Klipper, and an unknown name is refused" {
    rm -rf "$R/home/printer/klipper"
    run "$INSTALLER" settings
    [[ $output != *SOFTWARE* ]]
    run bash -c "printf 'SETTINGS=1\nSOFTWARE_rm_rf=on\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
    run bash -c "printf 'SETTINGS=1\nSOFTWARE_LED_EFFECT=on\n' | '$INSTALLER' configure"
    [ "$status" -ne 0 ]
}

@test "software: the vendored module is the author's, with its licence beside it" {
    head -8 "$PKG/rebuild-printer/usr/share/rebuild/klipper/optional/led_effect.py" | grep -q GPLv3
    grep -q "GNU GENERAL PUBLIC LICENSE" "$PKG/rebuild-printer/usr/share/rebuild/klipper/optional/led_effect.LICENSE"
}

# ---- include lists ----

tree_fixture() {
    local c="$R/home/printer/printer_data/config"
    mkdir -p "$c/firmware" "$c/peripherals/sensors" "$c/rebuild-reference" "$R/home/printer/printer_data/database"
    echo p > "$c/printer.cfg"; echo m > "$c/moonraker.conf"; echo f > "$c/firmware/stm32.config"
    echo r > "$c/firmware/stm32.reference"; echo b > "$c/.moonraker.conf.bkp"; echo x > "$c/rebuild-reference/generic.cfg"
    echo led > "$c/peripherals/led.cfg"; echo ch > "$c/peripherals/sensors/chamber.cfg"
    echo db > "$R/home/printer/printer_data/database/moonraker-sql.db"
}

@test "list: every saved file, a folder the user made included, nothing generated" {
    tree_fixture
    run "$INSTALLER" list
    [ "$status" -eq 0 ]
    [[ $output == *"home/printer/printer_data/config/peripherals/sensors/chamber.cfg"* ]]
    [[ $output == *"config/firmware/stm32.config"* && $output == *"database/moonraker-sql.db"* ]]
    [[ $output != *reference* && $output != *.bkp* ]]
}

@test "backup --include: only those files, the manifest first" {
    tree_fixture
    "$INSTALLER" backup --include home/printer/printer_data/config/printer.cfg --include home/printer/printer_data/config/peripherals > "$R/a.tgz"
    run tar -tzf "$R/a.tgz"
    [ "${lines[0]}" = rebuild-backup.manifest ]
    [[ $output == *"config/printer.cfg"* && $output == *"peripherals/sensors/chamber.cfg"* ]]
    [[ $output != *moonraker.conf* && $output != *database* ]]
}

@test "backup --include: a path outside what a backup holds is refused" {
    run "$INSTALLER" backup --include etc/shadow
    [ "$status" -ne 0 ]
    run "$INSTALLER" backup --include home/printer/printer_data/config/../../../../etc/shadow
    [ "$status" -ne 0 ]
    run "$INSTALLER" backup --bogus
    [ "$status" -ne 0 ]
}

@test "list-archive: what a restore would take, and not the manifest or anything else" {
    tree_fixture
    "$INSTALLER" backup > "$R/a.tgz"
    run "$INSTALLER" list-archive < "$R/a.tgz"
    [ "$status" -eq 0 ]
    [[ $output == *"config/printer.cfg"* && $output == *"database/moonraker-sql.db"* ]]
    [[ $output != *manifest* ]]
}

@test "restore --include: puts back only those files and leaves the rest of the config" {
    tree_fixture
    "$INSTALLER" backup > "$R/a.tgz"
    c="$R/home/printer/printer_data/config"
    echo changed > "$c/printer.cfg"; echo mine > "$c/moonraker.conf"; echo extra > "$c/extra.cfg"
    "$INSTALLER" restore --include home/printer/printer_data/config/printer.cfg < "$R/a.tgz"
    [ "$(cat "$c/printer.cfg")" = p ]
    [ "$(cat "$c/moonraker.conf")" = mine ]
    [ "$(cat "$c/extra.cfg")" = extra ]
}

@test "restore --include: a folder comes back laid over what is there" {
    tree_fixture
    "$INSTALLER" backup > "$R/a.tgz"
    c="$R/home/printer/printer_data/config"
    rm "$c/peripherals/led.cfg"; echo keep > "$c/peripherals/other.cfg"
    "$INSTALLER" restore --include home/printer/printer_data/config/peripherals < "$R/a.tgz"
    [ "$(cat "$c/peripherals/led.cfg")" = led ]
    [ "$(cat "$c/peripherals/sensors/chamber.cfg")" = ch ]
    [ "$(cat "$c/peripherals/other.cfg")" = keep ]
}

@test "restore without --include still replaces the whole config folder" {
    tree_fixture
    "$INSTALLER" backup > "$R/a.tgz"
    echo extra > "$R/home/printer/printer_data/config/extra.cfg"
    "$INSTALLER" restore < "$R/a.tgz"
    [ ! -e "$R/home/printer/printer_data/config/extra.cfg" ]
}

@test "restore --include: a path the backup does not hold is said, not made up" {
    tree_fixture
    "$INSTALLER" backup > "$R/a.tgz"
    run bash -c "'$INSTALLER' restore --include home/printer/printer_data/config/nothere.cfg < '$R/a.tgz' 2>&1"
    [[ $output == *"not in the backup"* ]]
    [ ! -e "$R/home/printer/printer_data/config/nothere.cfg" ]
}
