#!/bin/bash

install_moonraker(){
    UI=$1
    echo "🍰 install Moonraker"
    cd /home/debian
    git clone https://github.com/Arksine/moonraker
    # We add the ssh service here since the file is overwritten on the first boot.
    echo 'ssh' >> /home/debian/moonraker/moonraker/assets/default_allowed_services
    chown -R debian:debian moonraker
    su -c "/home/debian/moonraker/scripts/install-moonraker.sh" debian
    su -c "/home/debian/moonraker/scripts/set-policykit-rules.sh" debian
    cp /tmp/overlay/moonraker/moonraker-"${UI}".conf /home/debian/printer_data/config/moonraker.conf
}
