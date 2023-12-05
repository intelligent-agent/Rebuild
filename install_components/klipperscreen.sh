#!/bin/bash

install_klipperscreen() {
    cd /home/debian
    git clone https://github.com/jordanruthe/KlipperScreen.git
    chown -R debian:debian KlipperScreen
    su -c "/home/debian/KlipperScreen/scripts/KlipperScreen-install.sh" debian
}