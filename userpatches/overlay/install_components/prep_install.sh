#!/bin/bash

prepare_build() {
    echo "🍰 Prepare build"

    # The chroot shares the build container's hostname (a random container
    # id), which the image's /etc/hosts cannot resolve, so every sudo in the
    # Klipper, Moonraker and KlipperScreen installers printed "sudo: unable
    # to resolve host ...". Harmless, but 30-odd lines of noise per build.
    # Build-only: post_build takes the line out again.
    echo "127.0.1.1 $(hostname) # rebuild-build-only" >> /etc/hosts

    apt-get update
    apt-get install -y $PREP_PACKAGE_LIST --no-install-suggests --no-install-recommends

    # Ensure the debian user exists
    useradd -m -d /home/debian -s /bin/bash -G tty,dialout,sudo debian
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian

    # Add user printer, all top level software is installed to this user's home
    # directory. Klipper, Moonraker and KlipperScreen run as printer so that
    # debian's password can be expired below: sudo refuses an expired account,
    # and Moonraker restarts services through sudo. Not in the sudo group and
    # no password: its only root access is the NOPASSWD service commands in
    # /etc/sudoers.d/printer, and you reach it with `sudo -u printer -i`.
    useradd -m -d /home/printer -s /bin/bash -G tty,dialout,render,video printer

    # Give user install permissions during install. This line will be removed after the build.
    echo "printer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/printer
    
    # Set default passwords
    echo debian:temppwd | chpasswd
    echo root:temppwd | chpasswd

    # Force debian to change password
    chage -d 0 debian

    # Remove "dubious ownership" message when running git commands
    git config --global --add safe.directory '*'

    # Make folder for configs
    mkdir -p ${HOMEDIR}/printer_data/config
    chown -R printer:printer ${HOMEDIR}/printer_data
    chmod +x ${HOMEDIR}
}
