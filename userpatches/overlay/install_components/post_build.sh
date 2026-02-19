#!/bin/bash

post_build() {
    echo "🍰 Post build"

    apt update
    apt install -y "$ADD_PACKAGE_LIST" --no-install-suggests --no-install-recommends

    # Disable socket activation of ssh
    systemctl disable ssh.socket

    # Ssh needs to be enabled for moonraker to see it
    systemctl enable ssh.service

    # armbian-firstrun needs to be type=oneshot in order to the autodisable to wait for it.
    sed -i 's/Type=.*/Type=oneshot/' /lib/systemd/system/armbian-firstrun.service

    # Enable SSH service discovery
    cp /usr/share/doc/avahi-daemon/examples/ssh.service /etc/avahi/services/

    # Increase burstlimit on ssh
    sed '/RuntimeDirectoryMode=0755/a StartLimitBurst=10' /lib/systemd/system/ssh.service

    # Disable SSH root access
    sed -i 's/^PermitRootLogin.*$/#PermitRootLogin/g' /etc/ssh/sshd_config

    # Remove all temporary permission granted during install
    sed -i 's/printer ALL=(ALL) NOPASSWD: ALL//g' > /etc/sudoers.d/printer
    chmod 0440 /etc/sudoers.d/printer


    cat <<EOF > /etc/udev/rules.d/99-recore-otg.rules
# Trigger the ConfigFS script only when the role is 'device'
SUBSYSTEM=="usb_role", ATTR{role}=="device", RUN+="/usr/bin/systemctl start usb-gadget-setup.service"

# Tear down the gadget if the cable is removed or switched to host
SUBSYSTEM=="usb_role", ATTR{role}=="none", RUN+="/usr/bin/systemctl stop usb-gadget-setup.service"
SUBSYSTEM=="usb_role", ATTR{role}=="host", RUN+="/usr/bin/systemctl stop usb-gadget-setup.service"

# Start the login prompt only when the serial node appears
KERNEL=="ttyGS0", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="serial-getty@ttyGS0.service"
EOF

 cat <<EOF > /usr/local/bin/usb-gadget-init.sh
#!/bin/bash

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"
UDC_NAME="musb-hdrc.4.auto"

case "\$1" in
    start)
        modprobe libcomposite
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
        echo \$UDC_NAME > UDC
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
    
    cp /tmp/overlay/rebuild/rebuild-version /etc/
    # Backwards compatibility with refactor
    cp /tmp/overlay/rebuild/rebuild-version /etc/refactor.version

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    # Disable DNSsec
    mkdir -p /etc/systemd/resolved.conf.d/
    echo -e "[Resolve]\nDNSSEC=no" > /etc/systemd/resolved.conf.d/no-dnssec.conf

    # Automatically remount /boot rw when installing packages.
#    cat > /etc/apt/apt.conf.d/100update <<EOF
#DPkg::Pre-Invoke {"mount -o remount,rw /boot";};
#DPkg::Post-Invoke {"mount -o remount,ro /boot; /usr/local/bin/update-recore-revision";};
#EOF
}
