#!/bin/bash

install_klipper(){
    echo "🍰 install Klipper"
    cd /home/debian
    git clone https://github.com/Klipper3d/klipper
    cp /tmp/overlay/klipper/install-recore.sh /home/debian/klipper/scripts/
    cp /tmp/overlay/klipper/recore.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/thermocouple.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/generic-recore-a6.cfg /home/debian/klipper/config/
    cp /tmp/overlay/klipper/generic-recore-a7.cfg /home/debian/klipper/config/
    # Add compatibility with A5. 
    cp /tmp/overlay/klipper/recore_a5.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/recore_adc_temperature.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/recore_thermistor.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/generic-recore-a5.cfg /home/debian/klipper/config/
    cp /tmp/overlay/klipper/tmc2209_a5.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/tmc2130_a5.py /home/debian/klipper/klippy/extras/

	cp /tmp/overlay/klipper/flash-stm32 /usr/local/bin
	cp /tmp/overlay/klipper/flash-stm32.service /etc/systemd/system/
    mkdir -p /var/log/klipper_logs
    chown debian:debian /var/log/klipper_logs
    mkdir -p /opt/firmware/
    cp /tmp/overlay/klipper/bl31.bin /opt/firmware/
    chown -R debian:debian klipper
    chmod +x /home/debian/klipper/scripts/install-recore.sh
    su -c "/home/debian/klipper/scripts/install-recore.sh" debian
    wget http://feeds.iagent.no/toolchains/or1k-linux-musl-11.2.0.tar.xz -P /opt
    cd /opt
    tar -xf /opt/or1k-linux-musl-11.2.0.tar.xz
    rm /opt/or1k-linux-musl-11.2.0.tar.xz
    cp /tmp/overlay/klipper/ar100.config /home/debian/klipper/.config
    cd /home/debian/klipper/
    export PATH=$PATH:/opt/output/bin
	echo "export PATH=\$PATH:/opt/output/bin" >> /home/debian/.bashrc
    make olddefconfig
    make -j
    cp /home/debian/klipper/out/ar100.bin /opt/firmware
    cp /tmp/overlay/klipper/stm32f0.config /home/debian/klipper/.config
    make olddefconfig
    make -j
    cp /home/debian/klipper/out/klipper.bin /opt/firmware/stm32.bin
    chown -R debian:debian /home/debian/klipper
	systemctl enable flash-stm32.service
}
