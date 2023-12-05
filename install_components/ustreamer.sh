#!/bin/bash

install_ustreamer() {
    echo "🍰 install Ustreamer"
    cd /home/debian
    apt install -y build-essential libevent-dev libjpeg-dev libbsd-dev
    git clone https://github.com/pikvm/ustreamer
    cd /home/debian/ustreamer
    make -j
    echo 'SUBSYSTEM=="video4linux", ATTR{name}!="cedrus", ATTR{index}=="0", SYMLINK+="webcam", TAG+="systemd"' > /etc/udev/rules.d/50-video.rules
    echo '%debian ALL=NOPASSWD: /bin/systemctl restart ustreamer.service' >> /etc/sudoers.d/debian
    cp /tmp/overlay/ustreamer/ustreamer.service /etc/systemd/system/
    systemctl enable ustreamer.service
}