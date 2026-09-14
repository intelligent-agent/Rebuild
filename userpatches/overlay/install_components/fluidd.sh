#!/bin/bash

install_fluidd(){
    echo "🍰 install Fluidd"
    cd ${HOMEDIR}
    wget "https://github.com/fluidd-core/fluidd/releases/download/${FLUIDD_VERSION}/fluidd.zip"
    unzip fluidd.zip -d fluidd
    chown -R ${USER}:${USER} fluidd
    cp /tmp/overlay/fluidd/fluidd.cfg ${HOMEDIR}/printer_data/config
    chown ${USER}:${USER} ${HOMEDIR}/printer_data/config/fluidd.cfg
    rm fluidd.zip
}
