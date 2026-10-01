#!/bin/bash

post_build() {
    echo "🍰 Post build"

    # Added by prepare_build for the build container's hostname.
    sed -i '/# rebuild-build-only$/d' /etc/hosts

    apt-get update
    apt-get install -y "$ADD_PACKAGE_LIST" --no-install-suggests --no-install-recommends

    # Disable socket activation of ssh
    systemctl disable ssh.socket

    # Ssh needs to be enabled for moonraker to see it
    systemctl enable ssh.service

    # Enable SSH service discovery
    cp /usr/share/doc/avahi-daemon/examples/ssh.service /etc/avahi/services/

    # printer is a service account; useradd leaves it without a password, and
    # this keeps it that way even if something set one during the build.
    passwd -l printer

    strip_machine_identity

    # Remove all temporary permission granted during install
    sed -i 's/printer ALL=(ALL) NOPASSWD: ALL//g' /etc/sudoers.d/printer
    chmod 0440 /etc/sudoers.d/printer

    # Take armbian-config and armbian-install out. They exist to do the one
    # thing this product does not support: change the kernel or the bootloader
    # in place. Rebuild's position is that you flash a fresh image.
    #
    # The holds are not enough on their own. linux-image, linux-dtb,
    # linux-u-boot, armbian-firmware and base-files are all held, and a plain
    # `apt upgrade` does respect that - measured on an A8, "0 upgraded ... 5 not
    # upgraded", and `full-upgrade` the same. But armbian-config walks straight
    # past it: config.system.sh runs `apt-mark unhold`, makes the change and
    # re-holds, and config.software.sh passes --allow-change-held-packages.
    #
    # What that would install is the stock Armbian u-boot, carrying none of our
    # 14 patches. At least one is load-bearing: without the bootm_size fix a
    # Reflash USB boot dies at "ramdisk - allocation error". So the board would
    # be left looking like a hardware fault after nothing more exotic than a
    # menu selection.
    #
    # On Armbian main armbian-config is not installed at all: Armbian enables
    # its armbian-config extension unconditionally, and
    # userpatches/extensions/armbian-config.sh replaces it with an empty one.
    # The purge stays for a build without that override.
    #
    # armbian-config purges cleanly - nothing depends on it. armbian-install
    # cannot be purged: it is owned by armbian-bsp-cli-recore-current, the held
    # BSP package, so removing the package would gut the image. Delete the file.
    apt-get purge -y armbian-config || true
    rm -f /usr/bin/armbian-install

    cp /tmp/overlay/rebuild/rebuild-version /etc/
    # Backwards compatibility with refactor
    cp /tmp/overlay/rebuild/rebuild-version /etc/refactor.version

    TAG=$(cat /tmp/overlay/rebuild/rebuild-tag)
    sed -i "s/PRETTY_NAME=\"/PRETTY_NAME=\"Rebuild ${TAG}\//" /etc/os-release

    # Last, so nothing after it runs apt. Otherwise the image ships the
    # package indexes and .deb cache from build day (#100): tens of MB, and
    # an `apt install` on the board before any `apt update` would resolve
    # against stale lists. apt rebuilds pkgcache.bin on its next run.
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}
