#!/bin/bash

install_mainsail(){
    echo "🍰 install Mainsail"
    cd /home/debian
    wget -q -O mainsail.zip https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip 
    unzip mainsail.zip -d mainsail
    chown -R debian:debian mainsail
    cp /tmp/overlay/mainsail/mainsail.cfg /home/debian/printer_data/config
    rm mainsail.zip
}
