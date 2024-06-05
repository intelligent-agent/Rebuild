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
    cp /tmp/overlay/moonraker/moonraker.asvc /home/debian/printer_data/
    chown debian:debian moonraker /home/debian/printer_data/moonraker.asvc

    # Start moonraker only after armbian-firstrun
    sed -i 's/After=.*/After=network-online.target armbian-firstrun.service/' /etc/systemd/system/moonraker.service
}
