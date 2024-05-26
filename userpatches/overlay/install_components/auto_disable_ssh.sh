#!/bin/bash

install_auto_disable_ssh() {
    echo "🍰 install auto disable ssh script"
    # Install autohotspot script
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh /usr/local/bin
    chmod +x /usr/local/bin/aauto-disable-ss

    # Install autohotspot service file
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh.service /etc/systemd/system/
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh.timer /etc/systemd/system/

    systemctl enable auto-disable-ssh.timer
}
