#!/bin/bash

install_mainsail(){
    echo "🍰 install Mainsail"
    cd ${HOMEDIR}
    wget -q -O mainsail.zip https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip 
    unzip mainsail.zip -d mainsail
    chown -R ${USER}:${USER} mainsail
    cp /tmp/overlay/mainsail/mainsail.cfg ${HOMEDIR}/printer_data/config
    chown ${USER}:${USER} ${HOMEDIR}/printer_data/config/mainsail.cfg
    rm mainsail.zip
}
