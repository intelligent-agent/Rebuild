#!/bin/bash

install_klipper(){
    UI=$1
    echo "🍰 install Klipper"
    cd /home/debian
    git clone https://github.com/Klipper3d/klipper
    cp /tmp/overlay/klipper/install-recore.sh /home/debian/klipper/scripts/
    cp /tmp/overlay/klipper/ina381.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/generic-recore-a6.cfg /home/debian/klipper/config/
    cp /tmp/overlay/klipper/generic-recore-a7.cfg /home/debian/klipper/config/
    cp /tmp/overlay/klipper/generic-recore-a8.cfg /home/debian/klipper/config/
    # Add compatibility with A5. 
    cp /tmp/overlay/klipper/generic-recore-a5.cfg /home/debian/klipper/config/
    cp /tmp/overlay/klipper/recore_adc_temperature.py /home/debian/klipper/klippy/extras/
    cp /tmp/overlay/klipper/recore_thermistor.py /home/debian/klipper/klippy/extras/
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

    # Install AR100 toolchain
    wget http://feeds.iagent.no/toolchains/or1k-linux-musl-11.2.0.tar.xz -P /opt
    cd /opt
    tar -xf /opt/or1k-linux-musl-11.2.0.tar.xz
    rm /opt/or1k-linux-musl-11.2.0.tar.xz

    # Compile AR100
    cp /tmp/overlay/klipper/ar100.config /home/debian/klipper/.config
    cd /home/debian/klipper/
    export PATH=$PATH:/opt/output/bin
	echo "export PATH=\$PATH:/opt/output/bin" >> /home/debian/.bashrc
    make olddefconfig
    make -j
    cp /home/debian/klipper/out/ar100.bin /opt/firmware

    # Compile STM32
    cp /tmp/overlay/klipper/stm32f031-serial.config /home/debian/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp /home/debian/klipper/out/klipper.bin /opt/firmware/stm32.bin

    # Compile STM32-32KB
    cp /tmp/overlay/klipper/enable-i2c.patch /home/debian/klipper/
    patch -p1 < enable-i2c.patch
    cp /tmp/overlay/klipper/stm32f031-32KB-serial.config /home/debian/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp /home/debian/klipper/out/klipper.bin /opt/firmware/stm32-32KB.bin
    
    # Revert the patch to get rid of the warning
    git reset --hard

    chown -R debian:debian /home/debian/klipper
	systemctl enable flash-stm32.service

    if [ "${UI}" != "" ]; then
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' /home/debian/klipper/config/generic-recore-a5.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' /home/debian/klipper/config/generic-recore-a6.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' /home/debian/klipper/config/generic-recore-a7.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' /home/debian/klipper/config/generic-recore-a8.cfg
    fi
}
