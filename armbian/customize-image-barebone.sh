#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# This is the image customization script

# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed

# NOTE: If you want to transfer files between chroot and host
# userpatches/overlay directory on host is bind-mounted to /tmp/overlay in chroot
# The sd card's root path is accessible via $SDCARD variable.

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4
PREP_PACKAGE_LIST=""
ADD_PACKAGE_LIST="avahi-daemon"
USER=printer
HOMEDIR="/home/${USER}"

source /tmp/overlay/install_components/add_overlays.sh
source /tmp/overlay/install_components/autohotspot.sh
source /tmp/overlay/install_components/uboot_splash.sh
source /tmp/overlay/install_components/machine_identity.sh
source /tmp/overlay/install_components/barebone_console.sh
source /tmp/overlay/install_components/usb_gadget_getty.sh

# One tool, not install_bins: barebone stays minimal, and the rest of the bins
# belong to a printer this variant does not have.
#
# It earns its place because the rig asks a board which board it is before it
# writes anything to it, and barebone was the only variant that could not
# answer - so the check was skipped there by construction. On 2026-09-05 a job
# aimed at one board reached another that had taken the same DHCP lease and
# rebooted it; that one only cost a reboot, but the same mix-up on a rebuild
# image writes the stick. A guard that cannot fire on a quarter of the matrix
# is not a guard.
install_serial_tool() {
    echo "🍰 install get-serial-number"
    install -m 755 /tmp/overlay/bins/get-serial-number /usr/local/bin/get-serial-number
}

post_build() {
    
    cp /tmp/overlay/rebuild/rebuild-version /etc/
    apt update
    apt install -y "$ADD_PACKAGE_LIST"

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

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

    install_usb_gadget_getty
    strip_machine_identity

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

    # Automatically remount /boot rw when installing packages.
    cat > /etc/apt/apt.conf.d/100update <<EOF
DPkg::Pre-Invoke {"mount -o remount,rw /boot 2>/dev/null || true";};
DPkg::Post-Invoke {"mount -o remount,ro /boot 2>/dev/null || true";};
EOF
}

prep_install() {
    # install_autohotspot apt-installs dnsmasq-base, and barebone has no
    # prepare_build to have refreshed the lists first - post_build's apt update
    # runs after it, too late.
    apt update

    echo root:temppwd | chpasswd
}

echo "🍰 Rebuild starting..."

set -e

prep_install
add_overlays
install_autohotspot
install_uboot_splash
install_barebone_console
install_serial_tool
post_build

echo "🍰 Rebuild finished"
