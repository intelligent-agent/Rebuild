#!/bin/bash

install_klipperscreen() {
    echo "🍰 install KlipperScreen"
    cd "${HOMEDIR}"
    apt install -y python3-venv
    git clone https://github.com/jordanruthe/KlipperScreen.git
    chown -R ${USER}:${USER} KlipperScreen
    
    echo "printer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/printer
    su -c "SERVICE=y BACKEND=x NETWORK=n ${HOMEDIR}/KlipperScreen/scripts/KlipperScreen-install.sh" ${USER}
    echo "" > /etc/sudoers.d/printer
}
