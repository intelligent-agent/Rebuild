#!/bin/bash

KLIPPERSCREEN_TAG="v0.4.1"

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd /home/debian
    apt install python3.11-venv
    git clone https://github.com/jordanruthe/KlipperScreen.git
    cp /tmp/overlay/KlipperScreen/fix-missing-fi.patch /home/debian/KlipperScreen/
    cd KlipperScreen
    patch -p1 < fix-missing-fi.patch
    cd ..
    chown -R debian:debian KlipperScreen
    su -c "echo 'Y' | /home/debian/KlipperScreen/scripts/KlipperScreen-install.sh" debian
}
