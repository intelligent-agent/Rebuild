#!/bin/bash

prepare_build() {
    echo "🍰 Prepare build"

    apt update
    apt install -y $PREP_PACKAGE_LIST --no-install-suggests --no-install-recommends

    # Ensure the debian user exists
    useradd -m -d /home/debian -s /bin/bash -G tty,dialout,sudo debian
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian

    # Set default passwords
    echo debian:temppwd | chpasswd
    echo root:temppwd | chpasswd

    rm /root/.not_logged_in_yet

    # Remove "dubious ownership" message when running git commands
    git config --global --add safe.directory '*'

    # Make folder for configs
    mkdir -p /home/debian/printer_data/config
    chown -R debian:debian /home/debian/printer_data
    chmod +x /home/debian
}
