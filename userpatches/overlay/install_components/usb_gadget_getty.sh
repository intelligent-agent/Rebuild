#!/bin/bash

# Drop-ins for the login prompt on the USB gadget serial port.
#
# Every variant sets the gadget up in its own post_build, but these two
# overrides are subtle enough that a second copy would go stale, so they live
# here and are called from all four customize scripts.
install_usb_gadget_getty() {
    echo "🍰 install usb gadget getty"

    mkdir -p /etc/systemd/system/serial-getty@ttyGS0.service.d

    # Tie the getty's lifetime to the gadget's, or a reboot can end in a kernel
    # panic instead of a reboot (#86).
    #
    # Gadget teardown does `rmdir functions/acm.usb0`, which frees the gs_port -
    # but /dev/ttyGS0 belongs to u_serial's TTY driver and outlives it, so there
    # is a window where the node is still openable and its port is already gone.
    # Land in that window and tty_open fails, tty_release calls gs_close() on a
    # NULL port, and init takes a SIGSEGV:
    #
    #   lr : gs_close+0x24/0x240 [u_serial]
    #   Kernel panic - not syncing: Attempted to kill init!
    #
    # Nothing ordered the two before this. SYSTEMD_WANTS in the udev rule binds
    # the getty to dev-ttyGS0.device and to nothing else, so at shutdown - and
    # on every usb_role change that stops the gadget - the order was arbitrary.
    # After= gets the getty stopped first (shutdown is reverse-order), BindsTo=
    # takes it down whenever the gadget goes away for any other reason.
    cat <<'EOF' > /etc/systemd/system/serial-getty@ttyGS0.service.d/gadget.conf
[Unit]
BindsTo=usb-gadget-setup.service
After=usb-gadget-setup.service
EOF

    # Keep this getty away from /dev/console, or it deadlocks every other getty
    # on the board.
    #
    # A stock getty unit sets StandardInput=tty and TTYPath=/dev/%I, so systemd
    # opens the terminal itself, in the executor, before exec'ing agetty. Any
    # unit that may touch a terminal first takes systemd's *global* /dev/console
    # flock. Opening /dev/ttyGS0 blocks until carrier, and carrier here means a
    # USB host has opened the other end of the ACM port - so with no cable
    # attached that open never returns and the lock is never dropped. Observed
    # on a booted board, the whole login system stuck behind one unit:
    #
    #   serial-getty@ttyGS0  pid=315 exe=systemd-executor wchan=wait_woken
    #   serial-getty@ttyS0   pid=316 exe=systemd-executor wchan=locks_lock_inode_wait
    #   FLOCK ADVISORY WRITE 315 00:06:13 0 EOF        <- holder, inode 13 = /dev/console
    #   -> FLOCK ADVISORY WRITE 316 00:06:13 0 EOF     <- waiting
    #
    # Both units still report active/running the whole time, because systemd
    # considers a unit started once the executor is forked - it has not exec'd
    # agetty yet. That is why this looks healthy in systemctl and dead on the
    # panel, and why it comes and goes: attach a USB host before boot and
    # carrier is up, the open returns, and everything starts normally.
    #
    # So: no terminal stdio and no TTYPath, which means systemd never takes the
    # lock, and agetty opens the port itself - it uses O_NONBLOCK, so it does
    # not block waiting for carrier. The device has to be named explicitly
    # because the stock ExecStart passes `-`, meaning "the tty is already open
    # on stdin", which is exactly what is no longer true. TERM comes from the
    # environment for the same reason: systemd derives it from TTYPath, and
    # there no longer is one.
    cat <<'EOF' > /etc/systemd/system/serial-getty@ttyGS0.service.d/nolock.conf
[Service]
Environment=TERM=vt220
StandardInput=null
StandardOutput=null
StandardError=journal
TTYPath=
TTYReset=no
TTYVHangup=no
TTYVTDisallocate=no
ExecStart=
ExecStart=-/sbin/agetty -o '-- \\u' --noreset --noclear --keep-baud 115200,57600,38400,9600 %I ${TERM}
EOF
}
