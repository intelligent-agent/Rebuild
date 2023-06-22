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

install_ansible(){
    apt install ansible
    cd /usr/src/
    git clone https://github.com/intelligent-agent/Refactor.git
}

run_ansible_playbook(){
    cd /usr/src/Refactor
    ansible-playbook SYSTEM_klipper_mainsail-DEFAULT.yml
}

prepare_build() {
    echo "🍰 Prepare build"
    PACKAGE_LIST="avahi-daemon nginx git unzip iptables dnsmasq-base"
    PACKAGE_LIST+=" python3-virtualenv virtualenv python3-dev libffi-dev build-essential python3-cffi python3-libxml2"
    PACKAGE_LIST+=" libncurses-dev libusb-dev stm32flash libnewlib-arm-none-eabi gcc-arm-none-eabi binutils-arm-none-eabi "
    PACKAGE_LIST+=" unzip libavahi-compat-libdnssd1 libnss-mdns cpufrequtils pv "
    apt update
    apt install -y "$PACKAGE_LIST"

    # Ensure the debian user exists
    useradd debian -d /home/debian -G tty,dialout -m -s /bin/bash -e -1
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian

    # Set default passwords
    echo debian:temppwd | chpasswd
    echo root:temppwd | chpasswd

    # Remove "dubious ownership" message when running git commands
    git config --global --add safe.directory '*'

    # Disable SSH root access
    sed -i 's/^PermitRootLogin.*$/#PermitRootLogin/g' /etc/ssh/sshd_config

    # Disable SSH. Can be enabled in Reflash
    systemctl disable ssh

    echo "ttyGS0" >> /etc/securetty

    cp /tmp/overlay/rebuild/rebuild-version /etc/
}

post_build() {
    echo "🍰 Post build"
    # Force debian to change password
    chage -d 0 debian
}

set -e
echo "🍰 Rebuild starting..."
prepare_build
install_ansible
run_ansible_playbook
post_build

echo "🍰 Rebuild finished"
