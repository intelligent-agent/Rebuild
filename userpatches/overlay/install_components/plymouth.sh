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
