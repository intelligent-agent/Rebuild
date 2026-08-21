#!/bin/bash

install_plymouth() {
    echo "🍰 install Plymouth"
    apt install -y plymouth plymouth-themes

    # Recore's own theme, on the "script" plugin.
    #
    # spinner uses the "two-step" plugin, which blits its watermark 1:1. Once
    # simpledrm gave us the panel's real mode instead of a guessed 1024x768,
    # the same bitmap covered 10% of a 1920 canvas and 14% of a 1280 one, so
    # the logo was both smaller than before and inconsistent between panels
    # (#74). The script plugin can read the canvas at runtime and scale to it,
    # and it also gives us status/message hooks that two-step does not have.
    # Copy the whole theme directory rather than listing files. The theme is now
    # a script, two images and 34 animation frames, and a frame that fails to
    # copy does not fail loudly - Plymouth just renders nothing and you get a
    # black screen at boot with nothing in any log. A wildcard cannot go stale
    # the way a hand-maintained list can.
    install -d -m 755 /usr/share/plymouth/themes/recore
    install -m 644 /tmp/overlay/plymouth/recore/* /usr/share/plymouth/themes/recore/

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

    # Hold the splash across the handover to KlipperScreen.
    #
    # plymouth-quit finishes ~30ms before KlipperScreen.service even starts,
    # and KlipperScreen needs seconds more to paint, so the display went
    # black in between. --retain-splash leaves the last frame on screen
    # instead of clearing it.
    #
    # Ordering plymouth-quit after KlipperScreen is NOT an option:
    # KlipperScreen.service already has After=plymouth-quit-wait.service, so
    # that would be a dependency cycle for systemd to break arbitrarily.
    mkdir -p /etc/systemd/system/plymouth-quit.service.d
    cat <<'EOF' > /etc/systemd/system/plymouth-quit.service.d/retain-splash.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/plymouth quit --retain-splash
EOF

    # ...and stop X wiping that retained frame. Without -background none the
    # server paints a black root window before KlipperScreen draws, which
    # reintroduces the gap the line above just closed.
    if [ -f /etc/X11/xinit/xserverrc ]; then
        sed -i 's|exec /usr/bin/X -nolisten tcp|exec /usr/bin/X -nolisten tcp -background none|' /etc/X11/xinit/xserverrc
    fi
}
