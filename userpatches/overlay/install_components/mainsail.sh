#!/bin/bash

install_mainsail(){
    echo "🍰 install Mainsail"
    cd /home/debian
    wget https://github.com/intelligent-agent/mainsail/releases/latest/download/mainsail.zip
    unzip mainsail.zip -d mainsail
    chown -R debian:debian mainsail
    cp /tmp/overlay/mainsail/mainsail.cfg /home/debian/printer_data/config
}

install_mainsail_nginx(){
    echo "🍰 install Nginx"
    cp /tmp/overlay/nginx/upstreams.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/common_vars.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/mainsail /etc/nginx/sites-available
    rm /etc/nginx/sites-enabled/default
    ln -s /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail   
}