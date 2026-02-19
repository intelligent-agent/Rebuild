#!/bin/bash

install_moonraker(){
    UI=$1
    echo "🍰 install Moonraker"
    cd ${HOMEDIR}
    git clone https://github.com/Arksine/moonraker
    chown -R ${USER}:${USER} moonraker
    
    echo "printer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/printer
    su -c "${HOMEDIR}/moonraker/scripts/install-moonraker.sh" ${USER}
    echo "" > /etc/sudoers.d/printer

    mkdir -p /etc/polkit-1/rules.d/
    cp /tmp/overlay/moonraker/10-moonraker.rules /etc/polkit-1/rules.d/
    chmod 700 /etc/polkit-1/rules.d/
    chmod 600 /etc/polkit-1/rules.d/10-moonraker.rules
    chown -R root:root /etc/polkit-1/rules.d/

cat > /etc/sudoers.d/printer << EOF
printer ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ssh
printer ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart klipper
printer ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart moonraker
printer ALL=(ALL) NOPASSWD: /usr/sbin/reboot
EOF
chmod 0440 /etc/sudoers.d/printer

    cp /tmp/overlay/moonraker/moonraker-"${UI}".conf ${HOMEDIR}/printer_data/config/moonraker.conf
    cp /tmp/overlay/moonraker/moonraker.asvc ${HOMEDIR}/printer_data/
    chown ${USER}:${USER} moonraker ${HOMEDIR}/printer_data/moonraker.asvc

    
    # Start moonraker only after armbian-firstrun
    sed -i 's/After=.*/After=network-online.target armbian-firstrun.service/' /etc/systemd/system/moonraker.service
}
