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

post_build() {
    systemctl enable serial-getty@ttyGS0.service

    cp /tmp/overlay/rebuild/rebuild-version /etc/
    apt update
    apt install -y "$ADD_PACKAGE_LIST"

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    # Automatically remount /boot rw when installing packages.
    #cat > /etc/apt/apt.conf.d/100update <<EOF
#DPkg::Pre-Invoke {"mount -o remount,rw /boot";};
#DPkg::Post-Invoke {"mount -o remount,ro /boot; /usr/local/bin/update-recore-revision";};
#EOF
}

prep_install() {
    echo root:temppwd | chpasswd
}

echo "🍰 Rebuild starting..."

prep_install
add_overlays
install_autohotspot
post_build

echo "🍰 Rebuild finished"
