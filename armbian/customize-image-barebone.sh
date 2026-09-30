#!/bin/bash

# Must be set before any sourced build helper or package command runs.  The
# finished image deliberately has no regional locale archives.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

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

source /tmp/overlay/install_components/trim_image.sh
source /tmp/overlay/install_components/rebuild_packages.sh
source /tmp/overlay/install_components/add_overlays.sh
source /tmp/overlay/install_components/uboot_splash.sh
source /tmp/overlay/install_components/machine_identity.sh
source /tmp/overlay/install_components/barebone_console.sh
post_build() {
    
    cp /tmp/overlay/rebuild/rebuild-version /etc/
    apt-get update
    apt-get install -y "$ADD_PACKAGE_LIST"

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    strip_machine_identity

    # Automatically remount /boot rw when installing packages.
    cat > /etc/apt/apt.conf.d/100update <<EOF
DPkg::Pre-Invoke {"mount -o remount,rw /boot 2>/dev/null || true";};
DPkg::Post-Invoke {"mount -o remount,ro /boot 2>/dev/null || true";};
EOF
}

prep_install() {
    # install_rebuild_packages pulls in rebuild-recore's dependencies
    # (dnsmasq-base among them), and barebone has no prepare_build to have
    # refreshed the lists first - post_build's apt update runs too late.
    apt-get update

    echo root:temppwd | chpasswd
}

echo "🍰 Rebuild starting..."

set -e

trim_image
prep_install
# rebuild-recore, not rebuild-printer: the gadget console, autohotspot, and
# get-serial-number - the rig asks a board which board it is before writing
# to it, and barebone once could not answer (2026-09-05, a job reached a
# board that had taken another's DHCP lease). The rest is printer policy.
install_rebuild_packages rebuild-recore
add_overlays
install_uboot_splash
install_barebone_console
post_build

echo "🍰 Rebuild finished"
