#!/bin/bash

install_moonraker(){
    UI=$1
    echo "🍰 install Moonraker"
    cd /home/debian
    git clone https://github.com/Arksine/moonraker
    chown -R debian:debian moonraker
    su -c "/home/debian/moonraker/scripts/install-moonraker.sh" debian
    su -c "/home/debian/moonraker/scripts/set-policykit-rules.sh" debian
    cp /tmp/overlay/moonraker/moonraker-"${UI}".conf /home/debian/printer_data/config/moonraker.conf
}
