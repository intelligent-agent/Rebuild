#!/bin/bash

install_ustreamer() {
    echo "🍰 install Ustreamer"
    cd ${HOMEDIR}
    apt install -y build-essential libevent-dev libjpeg-dev libbsd-dev
    git clone https://github.com/pikvm/ustreamer
    cd ustreamer
    make -j
    echo 'SUBSYSTEM=="video4linux", ATTRS{idVendor}!="", ATTR{index}=="0", SYMLINK+="webcam", TAG+="systemd"' > /etc/udev/rules.d/50-video.rules
    echo '%printer ALL=NOPASSWD: /bin/systemctl restart ustreamer.service' >> /etc/sudoers.d/printer
    cp /tmp/overlay/ustreamer/ustreamer.service /etc/systemd/system/
    chown -R ${USER}:${USER} ${HOMEDIR}/ustreamer
    systemctl enable ustreamer.service
}
