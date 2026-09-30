#!/bin/bash

# rebuild-first-run ships in rebuild-printer, which deliberately does not
# enable it: on a board upgraded in place it has already run, and running it
# again would reflash the STM32 and RP2040. A fresh image is where it belongs.
install_rebuild_first_run() {
    echo "🍰 enable rebuild first run"
    systemctl enable rebuild-first-run.service
}
