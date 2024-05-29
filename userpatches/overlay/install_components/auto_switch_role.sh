#!/bin/bash

install_auto_switch_role() {
    echo "🍰 install automatic usb role switch"
    # Install autohotspot script
    cp /tmp/overlay/auto_switch_usb/usb-role-switch /usr/local/bin
    chmod +x /usr/local/bin/usb-role-switch

    # Install autohotspot service file
    cp /tmp/overlay/auto_switch_usb/usb-role-switch.service /etc/systemd/system/
    cp /tmp/overlay/auto_switch_usb/usb-role-switch.timer /etc/systemd/system/
}
