#!/bin/bash

install_moonraker(){
    UI=$1
    echo "🍰 install Moonraker"
    cd ${HOMEDIR}
    git clone https://github.com/Arksine/moonraker
    chown -R ${USER}:${USER} moonraker
    
    su -c "${HOMEDIR}/moonraker/scripts/install-moonraker.sh" ${USER}

    mkdir -p /etc/polkit-1/rules.d/
    cp /tmp/overlay/moonraker/10-moonraker.rules /etc/polkit-1/rules.d/
    chmod 700 /etc/polkit-1/rules.d/
    chmod 600 /etc/polkit-1/rules.d/10-moonraker.rules
    chown -R root:root /etc/polkit-1/rules.d/

    echo '%printer ALL=NOPASSWD: /bin/systemctl restart ssh' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl stop ssh' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl start ssh' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl restart klipper' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl stop klipper' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl start klipper' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl restart KlipperScreen' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl stop KlipperScreen' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl start KlipperScreen' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl restart moonraker' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl reboot' >> /etc/sudoers.d/printer
    echo '%printer ALL=NOPASSWD: /bin/systemctl poweroff' >> /etc/sudoers.d/printer

    cp /tmp/overlay/moonraker/moonraker-"${UI}".conf ${HOMEDIR}/printer_data/config/moonraker.conf
    cp /tmp/overlay/moonraker/moonraker.asvc ${HOMEDIR}/printer_data/
    chown ${USER}:${USER} moonraker ${HOMEDIR}/printer_data/moonraker.asvc

    
    # Start moonraker only after armbian-firstrun
    sed -i 's/After=.*/After=network-online.target armbian-firstrun.service/' /etc/systemd/system/moonraker.service
}
