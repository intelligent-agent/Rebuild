#!/bin/bash

# Rebuild's own files come as packages (packaging/), built by rebuild.sh into
# /tmp/overlay/debs. Installing them here, rather than copying files in, means
# a board gets the same thing from the image as it would from an apt upgrade.
install_rebuild_packages() {
    echo "🍰 install Rebuild packages: $*"
    local debs=() p
    for p in "$@"; do
        debs+=(/tmp/overlay/debs/"${p}"_*_all.deb)
    done
    apt-get install -y --no-install-recommends "${debs[@]}"
}
