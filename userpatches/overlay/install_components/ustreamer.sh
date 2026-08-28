#!/bin/bash

install_ustreamer() {
    echo "🍰 install Ustreamer"
    cd ${HOMEDIR}
    apt install -y build-essential libevent-dev libjpeg-dev libbsd-dev
    git clone https://github.com/pikvm/ustreamer
    cd ustreamer
    make -j
    # SYSTEMD_WANTS, not just TAG+="systemd", because the tag alone only makes
    # the device visible to systemd - it does not ask for anything to be started.
    #
    # WantedBy=dev-webcam.device in the unit puts a symlink in
    # dev-webcam.device.wants/, and systemd honours that when the device unit
    # transitions inactive -> active, i.e. a genuine hotplug. It does NOT act on
    # it for a camera that is already present when systemd starts, which is the
    # common case: on an A6 booted with a webcam fitted, dev-webcam.device was
    # active and listed Wants=ustreamer.service, yet ustreamer sat "inactive
    # (dead)" with no journal entries at all - never attempted. `udevadm trigger`
    # did not help either, since a re-add of an already-active device is not that
    # transition.
    #
    # SYSTEMD_WANTS is the documented way to bind a service to a device and works
    # for both coldplug and hotplug. Verified on that A6: with the property added
    # and udev reloaded, the same trigger that had done nothing brought ustreamer
    # up and it served :8080.
    echo 'SUBSYSTEM=="video4linux", ATTRS{idVendor}!="", ATTR{index}=="0", SYMLINK+="webcam", TAG+="systemd", ENV{SYSTEMD_WANTS}="ustreamer.service"' > /etc/udev/rules.d/50-video.rules
    echo '%printer ALL=NOPASSWD: /bin/systemctl restart ustreamer.service' >> /etc/sudoers.d/printer
    cp /tmp/overlay/ustreamer/ustreamer.service /etc/systemd/system/
    chown -R ${USER}:${USER} ${HOMEDIR}/ustreamer
    systemctl enable ustreamer.service
}
