#!/bin/bash

# Runs first, before anything is installed: dpkg only honours path-exclude for
# packages unpacked after the rule exists, so the Armbian base that is already
# in the chroot is cleaned up by hand here and everything later never lands.
trim_image() {
    echo "🍰 Trim image: English only, no source package cache"

    # srcpkgcache.bin (~46 MB) indexes source packages for `apt source`, which
    # nothing on a printer runs. pkgcache.bin is left alone: apt needs it, and
    # it is regenerated on the first apt run anyway.
    echo 'Dir::Cache::srcpkgcache "";' > /etc/apt/apt.conf.d/02-no-srcpkgcache
    rm -f /var/cache/apt/srcpkgcache.bin

    # Rebuild's user interfaces are English only, so message catalogues for the
    # other ~140 languages (~135 MB) and translated man pages are dead weight.
    # This covers only system translations under /usr/share; Fluidd, Mainsail,
    # KlipperScreen and OctoPrint carry their own and are untouched.
    cat > /etc/dpkg/dpkg.cfg.d/01-english-only <<'EOF'
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
path-include=/usr/share/locale/en*
path-exclude=/usr/share/man/*
path-include=/usr/share/man/man*
EOF
    find /usr/share/locale -mindepth 1 -maxdepth 1 \
        ! -name 'en*' ! -name locale.alias -exec rm -rf {} +
    find /usr/share/man -mindepth 1 -maxdepth 1 ! -name 'man*' -exec rm -rf {} +
}
