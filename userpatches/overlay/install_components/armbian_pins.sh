#!/bin/bash

# Pin Armbian's packages to the versions this image was built with (#114).
#
# These used to be frozen with apt-mark hold (BSPFREEZE), which nothing short
# of a reflash ever lifts. A pin can be moved: rebuild-armbian-tested ships
# only this preferences file, so releasing a kernel that Recore-CI has tested
# is publishing a newer rebuild-armbian-tested naming it, and boards take it
# as an ordinary System update in Fluidd - the new pins first, the packages
# on the next round.
#
# Exact-version Depends were tried and do not work: apt only ever considers a
# package's candidate, so a metapackage needing anything but the newest
# version cannot be installed at all.
#
# Must run before anything else here touches apt. With no hold and no pin,
# apt goes straight to the highest version in Armbian's repository.
ARMBIAN_PINNED="linux-image-* linux-dtb-* linux-u-boot-* armbian-bsp-cli-* armbian-firmware base-files"

pin_armbian_packages() {
    echo "🍰 pin Armbian packages to the versions in this image"
    local pkg=/tmp/rebuild-armbian-tested name version
    # A timestamp, not the Rebuild version: a later release - or a rollback,
    # which names an older kernel - has to sort above the image's own pins.
    local pkg_version
    pkg_version=$(date -u +%Y%m%d.%H%M%S)

    rm -rf "$pkg"
    mkdir -p "$pkg/DEBIAN" "$pkg/etc/apt/preferences.d"
    # shellcheck disable=SC2086  # the globs are dpkg-query patterns
    dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' $ARMBIAN_PINNED |
        while read -r status name version; do
            [ "$status" = ii ] || continue
            printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$name" "$version"
        done > "$pkg/etc/apt/preferences.d/rebuild-armbian-tested"
    cat "$pkg/etc/apt/preferences.d/rebuild-armbian-tested"
    # The kernel, device trees and U-Boot at least, or something was renamed
    # under us and would go out unpinned.
    for name in 'linux-image-' 'linux-dtb-' 'linux-u-boot-'; do
        grep -q "^Package: ${name}" "$pkg/etc/apt/preferences.d/rebuild-armbian-tested" || {
            echo "no ${name}* package to pin" >&2
            return 1
        }
    done

    cat > "$pkg/DEBIAN/control" <<EOF
Package: rebuild-armbian-tested
Version: ${pkg_version}
Architecture: all
Maintainer: Elias Bakken <elias@iagent.no>
Section: admin
Priority: optional
Description: Armbian package versions tested on Recore
 Pins Armbian's kernel, device trees, U-Boot, board support package,
 firmware and base-files to the versions Recore-CI has tested. A newer
 version of this package releases newer ones.
EOF
    # Not a conffile: a release has to replace it, and through PackageKit there
    # is nobody to answer dpkg's question about a locally edited one.
    dpkg-deb --build --root-owner-group "$pkg" /tmp/rebuild-armbian-tested.deb
    dpkg -i /tmp/rebuild-armbian-tested.deb
    rm -rf "$pkg" /tmp/rebuild-armbian-tested.deb
}
