#!/bin/bash

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd /home/debian
    apt install -y python3-venv
    git clone https://github.com/jordanruthe/KlipperScreen.git
    chown -R debian:debian KlipperScreen
    su -c "SERVICE=y BACKEND=x NETWORK=n /home/debian/KlipperScreen/scripts/KlipperScreen-install.sh" debian
}
