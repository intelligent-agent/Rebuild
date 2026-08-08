#!/bin/bash

install_auto_disable_ssh() {
    echo "🍰 install auto disable ssh script"
    # Install autohotspot script
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh /usr/local/bin
    chmod +x /usr/local/bin/auto-disable-ssh

    # Install autohotspot service file
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh.service /etc/systemd/system/
    cp /tmp/overlay/auto_disable_ssh/auto-disable-ssh.timer /etc/systemd/system/

    # install settings file (will later hold the plaintext wifi
    # password once Reflash writes real settings, so keep it
    # root-only from the start)
    cp /tmp/overlay/auto_disable_ssh/rebuild-settings /etc/
    chmod 600 /etc/rebuild-settings

    systemctl enable auto-disable-ssh.timer
}
