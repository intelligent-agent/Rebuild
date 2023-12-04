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

prepare_install(){
    apt update
    apt install -y python3-flask python3-requests pv xz-utils avahi-daemon unzip nginx gunicorn expect iptables dnsmasq-base

    # Set new password for root
    sh -c 'echo root:temppwd | chpasswd'

    # Add lost+found catalog and make it readable
    cd /boot
    mklost+found
    chmod +r /boot/lost+found

    echo "ttyGS0" >> /etc/securetty
    systemctl enable serial-getty@ttyGS0.service

}

install_reflash() {
    cd /usr/src
    wget https://github.com/intelligent-agent/Reflash/releases/download/v0.1.2-RC2/reflash.tar.gz
    tar -xf reflash.tar.gz
    cd reflash
    chmod +x ./scripts/install_reflash.sh
    ./scripts/install_reflash.sh
}

install_autohotspot() {
    # Install autohotspot script
    cp /tmp/overlay/autohotspot/autohotspot /usr/local/bin
    chmod +x /usr/local/bin/autohotspot

    # Install autohotspot service file
    cp /tmp/overlay/autohotspot/autohotspot.service /etc/systemd/system/

    systemctl enable autohotspot.service
}

add_overlays(){
    mkdir /boot/overlay-user
    cp /tmp/overlay/dts/* /boot/overlay-user
}

fix_netplan(){
    cat <<- EOF > /etc/netplan/armbian-default.yaml
		network:
		  version: 2
		  renderer: NetworkManager
	EOF
}

set -e

echo "🍰 Reflash starting..."
prepare_install
install_reflash
install_autohotspot
add_overlays
fix_netplan
echo "🍰 Custom script completed"
