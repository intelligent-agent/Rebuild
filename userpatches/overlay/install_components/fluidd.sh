#!/bin/bash

install_fluidd(){
    echo "🍰 install Fluidd"
    cd /home/debian
    wget https://github.com/fluidd-core/fluidd/releases/download/v1.24.1/fluidd.zip
    unzip fluidd.zip -d fluidd
    chown -R debian:debian fluidd
    cp /tmp/overlay/fluidd/fluidd.cfg /home/debian/printer_data/config
}

install_fluidd_nginx(){
    cp /tmp/overlay/nginx/upstreams.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/common_vars.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/fluidd /etc/nginx/sites-available
    rm /etc/nginx/sites-enabled/default
    ln -s /etc/nginx/sites-available/fluidd /etc/nginx/sites-enabled/fluidd
}