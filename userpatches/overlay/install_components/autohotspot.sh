#!/bin/bash

install_autohotspot() {
    echo "🍰 install Autohotspot"
    # Install autohotspot script
    cp /tmp/overlay/autohotspot/autohotspot /usr/local/bin
    chmod +x /usr/local/bin/autohotspot

    mkdir /etc/netplan/lib
    cp /tmp/overlay/autohotspot/*.yaml /etc/netplan/lib
    chmod 600 /etc/netplan/lib/*.yaml

    # Install autohotspot service file
    cp /tmp/overlay/autohotspot/autohotspot.service /etc/systemd/system/

    # Copy default settings file
    cp /tmp/overlay/autohotspot/rebuild-settings /etc/

    apt install -y dnsmasq-base

    systemctl enable autohotspot.service
}
