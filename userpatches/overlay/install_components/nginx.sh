#!/bin/bash

install_nginx(){
    UI=$1
    echo "🍰 install Nginx"
    apt-get install -y nginx --no-install-suggests --no-install-recommends
    cp /tmp/overlay/nginx/upstreams.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/common_vars.conf /etc/nginx/conf.d/
    cp /tmp/overlay/nginx/"$UI" /etc/nginx/sites-available
    rm /etc/nginx/sites-enabled/default
    ln -s /etc/nginx/sites-available/"$UI" /etc/nginx/sites-enabled/"$UI"
}