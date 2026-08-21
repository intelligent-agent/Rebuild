#!/bin/bash

post_build() {
    echo "🍰 Post build"

    apt update
    apt install -y "$ADD_PACKAGE_LIST" --no-install-suggests --no-install-recommends

    # Disable socket activation of ssh
    systemctl disable ssh.socket

    # Ssh needs to be enabled for moonraker to see it
    systemctl enable ssh.service

    # armbian-firstrun must be Type=oneshot so auto-disable-ssh.timer, ordered
    # After=armbian-firstrun.service, waits for it instead of racing it.
    # A drop-in, not sed: the unit belongs to armbian-bsp-cli, so an in-place
    # edit is silently undone on the next upgrade of that package.
    mkdir -p /etc/systemd/system/armbian-firstrun.service.d
    cat <<'EOF' > /etc/systemd/system/armbian-firstrun.service.d/oneshot.conf
[Service]
Type=oneshot
EOF

    # Enable SSH service discovery
    cp /usr/share/doc/avahi-daemon/examples/ssh.service /etc/avahi/services/

    # Stop root logging in over ssh with a password. prohibit-password, not no,
    # to match the previous behaviour: this used to comment out Armbian's
    # "PermitRootLogin yes", which falls back to OpenSSH's default of
    # prohibit-password - key logins were always still allowed.
    # sshd_config.d rather than sshd_config, which is a dpkg conffile.
    mkdir -p /etc/ssh/sshd_config.d
    cat <<'EOF' > /etc/ssh/sshd_config.d/10-recore-rootlogin.conf
PermitRootLogin prohibit-password
EOF

    # Remove all temporary permission granted during install
    sed -i 's/printer ALL=(ALL) NOPASSWD: ALL//g' /etc/sudoers.d/printer
    chmod 0440 /etc/sudoers.d/printer


    cat <<EOF > /etc/udev/rules.d/99-recore-otg.rules
# Bring the gadget up when the USB device controller appears. This is the
# trigger that works on every revision: only the A8 device tree declares a
# Type-C controller (fcs,fusb302 / usb-c-connector / usb-role-switch), so on
# A5, A6 and A7 there is no usb_role class device at all, the role rule below
# could never fire, and the board simply never enumerated - nothing in lsusb
# on the host (#75). Reflash hit the same thing and moved to this trigger.
SUBSYSTEM=="udc", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gadget-setup.service"

# Kept alongside the UDC rule rather than replaced by it. On A8 the role switch
# tears the gadget down when the cable is unplugged or flipped to host, and
# only this rule can bring it back: the UDC does not reappear, it is the
# controller itself and is present regardless of cable state. Starting an
# already-active oneshot with RemainAfterExit is a no-op, so the two triggers
# do not fight.
SUBSYSTEM=="usb_role", ATTR{role}=="device", RUN+="/usr/bin/systemctl start usb-gadget-setup.service"

# Tear down the gadget if the cable is removed or switched to host. These are
# also role-based and so also A8-only; on A5-A7 they never fire and the gadget
# stays up, which is what Reflash does on every revision.
SUBSYSTEM=="usb_role", ATTR{role}=="none", RUN+="/usr/bin/systemctl stop usb-gadget-setup.service"
SUBSYSTEM=="usb_role", ATTR{role}=="host", RUN+="/usr/bin/systemctl stop usb-gadget-setup.service"

# Start the login prompt only when the serial node appears
KERNEL=="ttyGS0", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="serial-getty@ttyGS0.service"
EOF

 cat <<EOF > /usr/local/bin/usb-gadget-init.sh
#!/bin/bash

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

case "\$1" in
    start)
        # usb_f_acm pulls in libcomposite and u_serial and registers the
        # usb_gadget configfs subsystem.
        modprobe usb_f_acm || { echo "modprobe usb_f_acm failed" >&2; exit 1; }

        # configfs registration is asynchronous - wait for it rather than
        # racing it.
        for i in \$(seq 1 50); do
            [ -d /sys/kernel/config/usb_gadget ] && break
            sleep 0.1
        done
        [ -d /sys/kernel/config/usb_gadget ] || { echo "usb_gadget configfs unavailable" >&2; exit 1; }

        # Bind to whichever UDC exists instead of a hardcoded name. The musb
        # platform device instance number comes from device tree ordering, so
        # it is not the same everywhere - this board has musb-hdrc.4.auto,
        # while Reflash's universal DTB gives musb-hdrc.2.auto.
        UDC_NAME="\$(ls /sys/class/udc 2>/dev/null | head -1)"
        [ -n "\$UDC_NAME" ] || { echo "no UDC available" >&2; exit 1; }

        mkdir -p \$GADGET_DIR
        cd \$GADGET_DIR

        echo 0x1d6b > idVendor
        echo 0x0104 > idProduct
        echo 0x0200 > bcdUSB

        mkdir -p strings/0x409
        echo "0123456789" > strings/0x409/serialnumber
        echo "Iagent" > strings/0x409/manufacturer
        echo "Recore USB Serial" > strings/0x409/product

        mkdir -p functions/acm.usb0
        mkdir -p configs/c.1/strings/0x409
        echo "Config 1: Serial" > configs/c.1/strings/0x409/configuration
        
        # Link function to config
        ln -s functions/acm.usb0 configs/c.1/ 2>/dev/null

        # Bind to hardware
        echo "\$UDC_NAME" > UDC
        ;;
    stop)
        if [ -d "\$GADGET_DIR" ]; then
            cd \$GADGET_DIR
            echo "" > UDC
            rm -f configs/c.1/acm.usb0
            [ -d "configs/c.1/strings/0x409" ] && rmdir configs/c.1/strings/0x409
            [ -d "configs/c.1" ] && rmdir configs/c.1
            [ -d "functions/acm.usb0" ] && rmdir functions/acm.usb0
            [ -d "strings/0x409" ] && rmdir strings/0x409
            cd ..
            rmdir g1
        fi
        ;;
esac
EOF

    chmod +x /usr/local/bin/usb-gadget-init.sh

cat <<EOF > /etc/systemd/system/usb-gadget-setup.service
[Unit]
Description=USB ConfigFS Gadget Manager

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gadget-init.sh start
ExecStop=/usr/local/bin/usb-gadget-init.sh stop
RemainAfterExit=yes

[Install]
EOF

    # Tie the getty's lifetime to the gadget's, or a reboot can end in a kernel
    # panic instead of a reboot (#86).
    #
    # The teardown above does `rmdir functions/acm.usb0`, which frees the
    # gs_port - but /dev/ttyGS0 belongs to u_serial's TTY driver and outlives
    # it, so there is a window where the node is still openable and its port is
    # already gone. serial-getty@ttyGS0 is a stock getty unit, so systemd opens
    # the device itself in PID 1; land in that window and tty_open fails,
    # tty_release calls gs_close() on a NULL port, and init takes a SIGSEGV:
    #
    #   lr : gs_close+0x24/0x240 [u_serial]
    #   Kernel panic - not syncing: Attempted to kill init!
    #
    # Nothing ordered the two before this. SYSTEMD_WANTS in the udev rule binds
    # the getty to dev-ttyGS0.device and to nothing else, so at shutdown - and
    # on every usb_role change that stops the gadget - the order was arbitrary.
    # After= gets the getty stopped first (shutdown is reverse-order), BindsTo=
    # takes it down whenever the gadget goes away for any other reason.
    mkdir -p /etc/systemd/system/serial-getty@ttyGS0.service.d
    cat <<'EOF' > /etc/systemd/system/serial-getty@ttyGS0.service.d/gadget.conf
[Unit]
BindsTo=usb-gadget-setup.service
After=usb-gadget-setup.service
EOF
    
    cp /tmp/overlay/rebuild/rebuild-version /etc/
    # Backwards compatibility with refactor
    cp /tmp/overlay/rebuild/rebuild-version /etc/refactor.version

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    # Disable DNSsec
    mkdir -p /etc/systemd/resolved.conf.d/
    echo -e "[Resolve]\nDNSSEC=no" > /etc/systemd/resolved.conf.d/no-dnssec.conf

    # Automatically remount /boot rw when installing packages.
    cat > /etc/apt/apt.conf.d/100update <<EOF
DPkg::Pre-Invoke {"mount -o remount,rw /boot 2>/dev/null || true";};
DPkg::Post-Invoke {"mount -o remount,ro /boot 2>/dev/null || true";};
EOF

    # Ask the watchdog for a timeout it can actually do (#82).
    #
    # systemd's default RebootWatchdogSec is 10min. sunxi-wdt maxes out at 16s
    # (/sys/class/watchdog/watchdog0/max_timeout), so the driver returns EINVAL,
    # systemd logs one line and carries on with the watchdog NEVER ARMED:
    #
    #   systemd-shutdown[1]: Failed to set watchdog hardware timeout to 10min:
    #   Invalid argument
    #
    # On a console that normally runs quiet, nobody sees it. So the protection
    # against a board wedging during shutdown has never been present.
    #
    # 15s is chosen against measurement, not taste: ten controlled shutdowns on
    # an A8 fluidd image all completed in 6-7s wall clock ("reboot: Power down"
    # at 8.07s on the serial console), and that is the *whole* shutdown - the
    # phase this timeout covers is a subset of it. So 15s is roughly 2x headroom
    # and still inside the 16s ceiling. Do not raise it past 16 or it silently
    # goes back to being unarmed.
    #
    # RuntimeWatchdogSec is deliberately NOT set here. Unlike this one it is
    # petted continuously, so the 16s ceiling is no obstacle - but it would
    # reset a printer that stalls for 16s mid-print, which is a product
    # decision rather than a bug fix.
    mkdir -p /etc/systemd/system.conf.d
    cat <<'EOF' > /etc/systemd/system.conf.d/10-watchdog.conf
[Manager]
RebootWatchdogSec=15s
EOF
}
