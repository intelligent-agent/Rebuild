#!/bin/bash

prepare_build() {
    echo "🍰 Prepare build"

    apt update
    apt install -y $PREP_PACKAGE_LIST --no-install-suggests --no-install-recommends

    # Ensure the debian user exists
    useradd -m -d /home/debian -s /bin/bash -G tty,dialout,sudo,render,video debian
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian

    # Add user printer, all top level software is installed to thios users home directory
    useradd -m -d /home/printer -s /bin/bash -G tty,dialout,sudo,render,video printer

    # Create a dedicated sudoers file for the printer user
    cat > /etc/sudoers.d/printer << EOF
# Allow printer user to reboot the machine
printer ALL=(ALL) NOPASSWD: /usr/sbin/reboot, /usr/sbin/shutdown, /usr/bin/systemctl reboot, /usr/bin/systemctl halt

# Allow printer user to restart Klipper and Moonraker services
printer ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart klipper, /usr/bin/systemctl restart moonraker, /usr/bin/systemctl stop klipper, /usr/bin/systemctl stop moonraker
EOF

    # Ensure the file has the strict permissions Linux requires
    chmod 0440 /etc/sudoers.d/printer

    # Set default passwords
    echo debian:temppwd | chpasswd
    echo printer:temppwd | chpasswd
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
