#!/bin/bash
# vim:ts=4:sw=4:sts=4:et:ai

# Variables
KLPUSER="debian"
KLPGROUP="debian"
HOMEDIR="/home/$KLPUSER"
TMPDIR="/tmp/overlay"
LOGDIR="/var/log/klipper_logs"
FWDIR="/opt/firmware"
KLIPPER_URL="https://github.com/Klipper3d/klipper"
AR100TC_URL="http://feeds.iagent.no/toolchains/or1k-linux-musl-11.2.0.tar.xz"

# Code
install_klipper() {
    echo "🍰 install Klipper"
    cd $HOMEDIR
    git clone $KLIPPER_URL
    cp $TMPDIR/klipper/install-recore.sh $HOMEDIR/klipper/scripts/
    cp $TMPDIR/klipper/recore.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/thermocouple.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/generic-recore-a6.cfg $HOMEDIR/klipper/config/
    cp $TMPDIR/klipper/generic-recore-a7.cfg $HOMEDIR/klipper/config/
    cp $TMPDIR/klipper/generic-recore-a8.cfg $HOMEDIR/klipper/config/
    # Add compatibility with A5.
    cp $TMPDIR/klipper/recore_a5.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/recore_adc_temperature.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/recore_thermistor.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/generic-recore-a5.cfg $HOMEDIR/klipper/config/
    cp $TMPDIR/klipper/tmc2209_a5.py $HOMEDIR/klipper/klippy/extras/
    cp $TMPDIR/klipper/tmc2130_a5.py $HOMEDIR/klipper/klippy/extras/

    cp $TMPDIR/klipper/flash-stm32 /usr/local/bin
    cp $TMPDIR/klipper/flash-stm32.service /etc/systemd/system/
    mkdir -p $LOGDIR
    chown $KLPUSER:$KLPGROUP $LOGDIR
    mkdir -p $FWDIR
    cp $TMPDIR/klipper/bl31.bin $FWDIR
    chown -R $KLPUSER:$KLPGROUP klipper
    chmod +x $HOMEDIR/klipper/scripts/install-recore.sh
    su -c "$HOMEDIR/klipper/scripts/install-recore.sh" $KLPUSER

    # Install AR100 toolchain
    wget $AR100TC_URL -P /opt
    cd /opt
    tar -xf /opt/or1k-linux-musl-11.2.0.tar.xz
    rm /opt/or1k-linux-musl-11.2.0.tar.xz

    # Compile AR100
    cp $TMPDIR/klipper/ar100.config $HOMEDIR/klipper/.config
    cd $HOMEDIR/klipper/
    export PATH=$PATH:/opt/output/bin
	echo "export PATH=\$PATH:/opt/output/bin" >> $HOMEDIR/.bashrc
    make olddefconfig
    make -j
    cp $HOMEDIR/klipper/out/ar100.bin /opt/firmware

    # Compile STM32
    cp $TMPDIR/klipper/stm32f031-serial.config $HOMEDIR/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp $HOMEDIR/klipper/out/klipper.bin /opt/firmware/stm32.bin

    # Compile STM32-32KB
    cp $TMPDIR/klipper/enable-i2c.patch $HOMEDIR/klipper/
    patch -p1 < enable-i2c.patch
    cp $TMPDIR/klipper/stm32f031-32KB-serial.config $HOMEDIR/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp $HOMEDIR/klipper/out/klipper.bin /opt/firmware/stm32-32KB.bin

    # Revert the patch to get rid of the warning
    git reset --hard

    chown -R $KLPUSER:$KLPGROUP $HOMEDIR/klipper
	systemctl enable flash-stm32.service
}
