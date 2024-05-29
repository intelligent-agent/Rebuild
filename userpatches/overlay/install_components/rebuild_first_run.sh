#!/bin/bash

install_rebuild_first_run() {
    echo "🍰 install rebuild first run"

    # Install script
    cp /tmp/overlay/rebuild-first-run/rebuild-first-run /usr/local/bin
    chmod +x /usr/local/bin/rebuild-first-run

    # Install and enable service file
    cp /tmp/overlay/rebuild-first-run/rebuild-first-run.service /etc/systemd/system/
    systemctl enable rebuild-first-run.service
}
