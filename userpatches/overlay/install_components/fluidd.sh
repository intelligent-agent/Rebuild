#!/bin/bash

install_fluidd(){
    echo "🍰 install Fluidd"
    cd /home/debian
    wget https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip
    unzip fluidd.zip -d fluidd
    chown -R debian:debian fluidd
    cp /tmp/overlay/fluidd/fluidd.cfg /home/debian/printer_data/config
    rm fluidd.zip
}
