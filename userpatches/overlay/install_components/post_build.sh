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

    cat <<EOF > /etc/udev/rules.d/99-recore-otg.rules
# Only start getty if ttyGS0 (Gadget Serial) is actually initialized by the kernel
KERNEL=="ttyGS0", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="serial-getty@ttyGS0.service"
EOF

    cat <<EOF > /usr/local/bin/usb-gadget-init.sh
#!/bin/bash
# Load the composite framework
modprobe libcomposite

# Create the gadget configuration directory
cd /sys/kernel/config/usb_gadget/
mkdir -p g1
cd g1

# Define Device ID and Identifiers
# These match the standard Linux USB Serial Gadget IDs
echo 0x1d6b > idVendor  # Linux Foundation
echo 0x0104 > idProduct # Multifunction Composite Gadget
echo 0x0100 > bcdDevice # v1.0.0
echo 0x0200 > bcdUSB    # USB 2.0

# Create string descriptors (Manufacturer, Product, Serial)
mkdir -p strings/0x409
echo "0123456789" > strings/0x409/serialnumber
echo "Iagent" > strings/0x409/manufacturer
echo "Recore USB Serial" > strings/0x409/product

# Create the Serial function (ACM is the standard for Serial Gadgets)
mkdir -p functions/acm.usb0

# Create the configuration
mkdir -p configs/c.1/strings/0x409
echo "Config 1: Serial" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# Bind the Serial function to this configuration
ln -s functions/acm.usb0 configs/c.1/

# Final Step: Bind the entire gadget to the UDC (Universal Device Controller)
# This is what "plugs it in" logically to your hardware
echo "" > UDC 2>/dev/null || true
echo "musb-hdrc.4.auto" > UDC
EOF
    chmod +x /usr/local/bin/usb-gadget-init.sh
    
    cat <<EOF > /etc/systemd/system/usb-gadget-setup.service
[Unit]
Description=Initialize USB ConfigFS Gadget
After=usb-gadget.target
Requires=usb-gadget.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gadget-init.sh
RemainAfterExit=yes

[Install]
WantedBy=usb-gadget.target
EOF
    systemctl enable usb-gadget-setup.service
    
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
