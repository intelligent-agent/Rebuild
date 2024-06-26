#!/bin/bash

post_build() {
    echo "🍰 Post build"

    apt update
    apt install -y "$ADD_PACKAGE_LIST" --no-install-suggests --no-install-recommends

    # Disable socket activation of ssh
    systemctl disable ssh.socket

    # Ssh needs to be enabled for moonraker to see it
    systemctl enable ssh.service

    # armbian-firstrun needs to be type=oneshot in order to the autodisable to wait for it.
    sed -i 's/Type=.*/Type=oneshot/' /lib/systemd/system/armbian-firstrun.service

    # Enable SSH service discovery
    cp /usr/share/doc/avahi-daemon/examples/ssh.service /etc/avahi/services/

    # Increase burstlimit on ssh
    sed '/RuntimeDirectoryMode=0755/a StartLimitBurst=10' /lib/systemd/system/ssh.service

    # Disable SSH root access
    sed -i 's/^PermitRootLogin.*$/#PermitRootLogin/g' /etc/ssh/sshd_config

    echo "ttyGS0" >> /etc/securetty
    systemctl enable serial-getty@ttyGS0.service

    cp /tmp/overlay/rebuild/rebuild-version /etc/
    # Backwards compatibility with refactor
    cp /tmp/overlay/rebuild/rebuild-version /etc/refactor.version

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    # Force debian to change password
    # Must be done as a final step
    chage -d 0 debian

    # Disable the upstream kernel driver for Rexfer/rtw88_rtl8821cu
    echo "blacklist rtw88_8821cu" > /etc/modprobe.d/blacklist.conf

    # Automatically remount /boot rw when installing packages.
    cat > /etc/apt/apt.conf.d/100update <<EOF
DPkg::Pre-Invoke {"mount -o remount,rw /boot";};
DPkg::Post-Invoke {"mount -o remount,ro /boot; /usr/local/bin/update-recore-revision";};
EOF
}
