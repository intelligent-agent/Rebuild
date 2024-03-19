#!/bin/bash

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd /home/debian
    git clone https://github.com/jordanruthe/KlipperScreen.git
    chown -R debian:debian KlipperScreen
    su -c "echo 'Y' | /home/debian/KlipperScreen/scripts/KlipperScreen-install.sh" debian
}