#!/bin/bash

install_plymouth() {
    echo "🍰 install Plymouth"
    apt-get install -y plymouth plymouth-themes

    # Test variant: force SimpleDRM inclusion and loading in the initramfs.
    install -m 0644 /tmp/overlay/etc/initramfs-tools/modules /etc/initramfs-tools/modules

    # Recore's own theme, on the "script" plugin. The files ship in
    # rebuild-printer (packaging/), installed before this runs.
    #
    # spinner uses the "two-step" plugin, which blits its watermark 1:1. Once
    # simpledrm gave us the panel's real mode instead of a guessed 1024x768,
    # the same bitmap covered 10% of a 1920 canvas and 14% of a 1280 one, so
    # the logo was both smaller than before and inconsistent between panels
    # (#74). The script plugin can read the canvas at runtime and scale to it,
    # and it also gives us status/message hooks that two-step does not have.
    plymouth-set-default-theme -R recore

    # ...and make sure -R actually regenerated something.
    #
    # -c, not -u. The kernel is installed *before* customize-image.sh runs and
    # its postinst defers the initramfs, so at this point /boot/initrd.img-*
    # does not exist yet and there is nothing to update - `update-initramfs -u`
    # is a no-op and the deferred trigger later wraps a stale or absent initrd.
    # Create it here instead, now that the theme is set.
    KVER=$(ls /lib/modules | head -1)
    if [ -z "$KVER" ]; then
        echo "FATAL: no kernel in /lib/modules - cannot build an initramfs" >&2
        exit 1
    fi
    update-initramfs -c -k "$KVER" 2>&1 | tail -3 || update-initramfs -u -k "$KVER" 2>&1 | tail -3

    # Check that the theme is installed and that initramfs-tools resolves it -
    # the hook reads `plymouth-set-default-theme` and copies whatever that
    # names, so a theme that is present but not selected fails silently and can
    # only be caught by looking at a booted panel.
    #
    # This does NOT prove the shipped image gets this initrd, and must not be
    # read that way: Armbian's own initrd step runs later, and on a cache hit it
    # copies a previously cached initramfs straight over this file. Its cache
    # key does not hash anything under /etc/plymouth or /usr/share/plymouth, so
    # a theme change alone never invalidates it. That is what actually caused
    # #74. After changing the theme, clear the cache by hand before building -
    # see the note above ./compile.sh in rebuild.sh.
    IRD=/boot/initrd.img-$KVER
    if [ ! -f "$IRD" ] || ! lsinitramfs "$IRD" | grep -q 'themes/recore/recore.script'; then
        echo "FATAL: initramfs-tools did not pick up the recore theme" >&2
        echo "FATAL: check 'plymouth-set-default-theme' and /etc/plymouth/plymouthd.conf" >&2
        ls -l /boot/ >&2
        exit 1
    fi
    echo "🍰 recore theme resolved by initramfs-tools"
    if ! lsinitramfs "$IRD" | grep -q '/simpledrm\.ko'; then
        echo "FATAL: SimpleDRM module is missing from the test initramfs" >&2
        exit 1
    fi

    # The splash is held across the handover to KlipperScreen by the
    # plymouth-quit --retain-splash drop-in in rebuild-printer...

    # ...and stop X wiping that retained frame. Without -background none the
    # server paints a black root window before KlipperScreen draws, which
    # reintroduces the gap the line above just closed.
    if [ -f /etc/X11/xinit/xserverrc ]; then
        sed -i 's|exec /usr/bin/X -nolisten tcp|exec /usr/bin/X -nolisten tcp -background none|' /etc/X11/xinit/xserverrc
    fi
}
