#!/bin/bash

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd "${HOMEDIR}"
    apt install -y python3-venv
    git clone https://github.com/jordanruthe/KlipperScreen.git
    chown -R ${USER}:${USER} KlipperScreen
    su -c "SERVICE=y BACKEND=x NETWORK=n ${HOMEDIR}/KlipperScreen/scripts/KlipperScreen-install.sh" ${USER}

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
}
