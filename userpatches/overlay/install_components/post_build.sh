#!/bin/bash

post_build() {
    echo "🍰 Post build"

    apt update
    apt install -y "$ADD_PACKAGE_LIST" --no-install-suggests --no-install-recommends

    # Disable SSH. Can be enabled in Reflash
    systemctl disable ssh

    # Increase burstlimit on ssh
    sed '/RuntimeDirectoryMode=0755/a StartLimitBurst=10' /lib/systemd/system/ssh.service

    # Reload daemon after change. Might help with Rebuild isue #27
    systemctl daemon-reload

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
}
