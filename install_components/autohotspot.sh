#!/bin/bash

install_autohotspot() {
    echo "🍰 install Autohotspot"
    # Install autohotspot script
    cp /tmp/overlay/autohotspot/autohotspot /usr/local/bin
    chmod +x /usr/local/bin/autohotspot

    # Install autohotspot service file
    cp /tmp/overlay/autohotspot/autohotspot.service /etc/systemd/system/

    systemctl enable autohotspot.service
}