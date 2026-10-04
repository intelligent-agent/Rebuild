#!/bin/bash

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd "${HOMEDIR}"
    apt-get install -y python3-venv
    git clone https://github.com/jordanruthe/KlipperScreen.git
    git -C KlipperScreen reset --hard "${KLIPPERSCREEN_VERSION}"
    chown -R ${USER}:${USER} KlipperScreen
    # Use upstream's native Wayland/Weston installation and launcher. No
    # installer rewrite, tracked source patch or separate compositor service.
    su -c "SERVICE=y BACKEND=W COMPOSITOR=weston NETWORK=n START=0 ${HOMEDIR}/KlipperScreen/scripts/KlipperScreen-install.sh" ${USER}

    # Use the standard path already understood by Reflash's WESTON rotation
    # step. Prefer the attached panel's mode; never hard-code Voron's resolution
    # or rotation into an image shared by different rigs. Reflash integration
    # for Fluidd is deliberately deferred; adjust transform manually for tests.
    install -Dm644 /tmp/overlay/install_components/klipperscreen-weston.ini \
        /etc/xdg/weston/weston.ini

    # The installer adds Korean and Japanese fonts (~61 MB) for KlipperScreen's
    # CJK translations; Rebuild ships English only, and DejaVu stays for the UI.
    # Moonraker will not put them back on an update: with install_script it only
    # reinstalls packages from PKGLIST="..." lines, and this installer has none.
    apt-get purge -y fonts-nanum fonts-ipafont fonts-ipafont-gothic fonts-ipafont-mincho

    # Stop systemd acquiring a terminal for this unit (#83).
    #
    # Upstream's unit carries TTYPath=/dev/tty7 with TTYReset/TTYVHangup/
    # TTYVTDisallocate, so systemd acquires and resets a terminal on every start
    # *and* stop. On Recore that takes an exclusive flock on /dev/console - which
    # is ttyS0, the port serial-getty@ttyS0 runs agetty on. agetty holds that
    # lock, so PID 1 blocks in flock(); it is single-threaded, and init stops
    # answering entirely: no new logins (ssh authenticates and never gets a
    # shell), no systemctl, and no way to reboot except sysrq or the power
    # switch. klipper keeps printing throughout, which makes it look healthy.
    #
    # Restart=always is what makes this more than a manual-restart bug: a
    # KlipperScreen crash while anyone is on the serial console wedges the board
    # with no user action at all.
    #
    # These settings exist to hand X a clean VT. They buy nothing here - no VT is
    # a console on this board (/proc/consoles lists ttyS0 alone) - and X starts
    # and drives the panel exactly as before without them. Verified on an A8:
    # four consecutive restarts with a serial login active, PID 1 never queued,
    # Xorg up and holding card0 each time.
    mkdir -p /etc/systemd/system/KlipperScreen.service.d
    cat <<'EOF' > /etc/systemd/system/KlipperScreen.service.d/no-tty-acquire.conf
[Service]
TTYPath=
TTYReset=no
TTYVHangup=no
TTYVTDisallocate=no
EOF

    # GTK must use native Wayland rather than silently falling back to X11.
    # seatd's video-group socket is accessible to the existing printer user.
    cat <<'EOF' > /etc/systemd/system/KlipperScreen.service.d/wayland.conf
[Service]
Environment=GDK_BACKEND=wayland
Environment=LIBSEAT_BACKEND=seatd
EOF
}
