#!/bin/bash

install_autohotspot() {
    echo "🍰 install Autohotspot"
    # Install autohotspot script
    cp /tmp/overlay/autohotspot/autohotspot /usr/local/bin
    chmod +x /usr/local/bin/autohotspot

    # Install autohotspot service file
    cp /tmp/overlay/autohotspot/autohotspot.service /etc/systemd/system/

    # Keeps replies from the Wi-Fi address on Wi-Fi when the board also has
    # Ethernet on the same subnet - see the script for what that costs.
    install -m 755 -o root -g root /tmp/overlay/autohotspot/wifi-source-routing \
        /etc/NetworkManager/dispatcher.d/90-wifi-source-routing

    apt install -y dnsmasq-base

    systemctl enable autohotspot.service
}
