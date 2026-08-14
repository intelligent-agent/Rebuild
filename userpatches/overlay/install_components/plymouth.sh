#!/bin/bash

install_plymouth() {
    echo "🍰 install Plymouth"
    apt install -y plymouth plymouth-themes

    # Use Recore's own watermark as the spinner theme's logo. The
    # theme's default WatermarkVerticalAlignment (.96) puts it right
    # near the bottom of the screen - center it instead.
    cp /tmp/overlay/plymouth/watermark.png /usr/share/plymouth/themes/spinner/watermark.png
    sed -i 's/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.5/' /usr/share/plymouth/themes/spinner/spinner.plymouth

    plymouth-set-default-theme -R spinner

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
