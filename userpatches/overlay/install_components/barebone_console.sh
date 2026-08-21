#!/bin/bash

install_barebone_console() {
    echo "🍰 install barebone console"

    # Barebone has no Plymouth and no KlipperScreen, so nothing ever draws to
    # the panel after u-boot - the boot splash simply stays there. A getty does
    # run on tty1, but it is invisible: fbcon defers its console take-over and
    # then never performs it, because the kernel console is serial only
    # (console=serial in bootenv) so nothing writes to the VT to trigger it.
    # Observed on a booted board:
    #
    #     fbcon: Deferring console take-over
    #     vtcon0: (S) dummy device bound=1
    #
    # nodefer makes fbcon bind at boot instead. Deliberately barebone-only: on
    # the other variants the deferral is what stops fbcon clobbering the splash
    # before Plymouth takes the display, so it is wanted there.
    #
    # fbcon=rotate:3 ships alongside it on purpose. Reflash's rotate-screen
    # decides whether to ADD fbcon=rotate:N by grepping for "fbcon=", but its
    # sed only rewrites "fbcon=rotate:" - so an image carrying nodefer alone
    # matches the guard, skips the add, and ends up with no rotation at all.
    # Having a rotate: value already present gives that sed something to
    # rewrite. Reflash #125 tightens the guard; this stays correct either way.
    if [ ! -f /boot/armbianEnv.txt ]; then
        echo "FATAL: /boot/armbianEnv.txt is missing - cannot set fbcon=nodefer" >&2
        ls -l /boot/ >&2
        exit 1
    fi
    sed -i '/^extraargs=/ s/$/ fbcon=rotate:3 fbcon=nodefer/' /boot/armbianEnv.txt
    grep '^extraargs=' /boot/armbianEnv.txt

    # ...and give that console a shell rather than a login prompt. This is a
    # development image with no user accounts beyond root, and the panel usually
    # has no keyboard attached, so a password prompt there helps nobody.
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat <<'AUTOLOGIN' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN
}
