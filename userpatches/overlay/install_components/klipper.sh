#!/bin/bash

install_klipper(){
    UI=$1
    echo "🍰 install Klipper"
    cd "${HOMEDIR}"
    git clone https://github.com/Klipper3d/klipper

    sed -i 's/select HAVE_GPIO_I2C if !MACH_STM32F031/select HAVE_GPIO_I2C/' klipper/src/stm32/Kconfig

    # We create an empty file here to give the right permissions
    touch ${HOMEDIR}/printer_data/config/printer.cfg
    chown ${USER}:${USER} ${HOMEDIR}/printer_data/config/printer.cfg
    
    cp /tmp/overlay/klipper/generic-recore-a6.cfg ${HOMEDIR}/klipper/config/
    cp /tmp/overlay/klipper/generic-recore-a7.cfg ${HOMEDIR}/klipper/config/
    cp /tmp/overlay/klipper/generic-recore-a8.cfg ${HOMEDIR}/klipper/config/
    # Add compatibility with A5. 
    cp /tmp/overlay/klipper/generic-recore-a5.cfg ${HOMEDIR}/klipper/config/
    cp /tmp/overlay/klipper/recore_adc_temperature.py ${HOMEDIR}/klipper/klippy/extras/
    cp /tmp/overlay/klipper/recore_thermistor.py ${HOMEDIR}/klipper/klippy/extras/
    cp /tmp/overlay/klipper/tmc2209_a5.py ${HOMEDIR}/klipper/klippy/extras/
    cp /tmp/overlay/klipper/tmc2130_a5.py ${HOMEDIR}/klipper/klippy/extras/

    cp /tmp/overlay/klipper/flash-stm32 /usr/local/bin
    cp /tmp/overlay/klipper/flash-rp2040 /usr/local/bin
    # Ships with flash-rp2040 because it exists solely to keep that script quiet:
    # the RP2 bootloader presents a mass-storage interface we never use, and udev
    # probing it produces I/O errors on every first boot (#94).
    mkdir -p /etc/udev/rules.d
    cp /tmp/overlay/klipper/55-rp2040-bootloader.rules /etc/udev/rules.d/
    cp /tmp/overlay/klipper/flash-ar100.py /usr/local/bin
    cp /tmp/overlay/klipper/set-ar100-clock.py /usr/local/bin
    chmod +x /usr/local/bin/flash-ar100.py /usr/local/bin/set-ar100-clock.py /usr/local/bin/flash-rp2040
    mkdir -p /var/log/klipper_logs
    chown ${USER}:${USER} /var/log/klipper_logs
    mkdir -p /opt/firmware/
    cp /tmp/overlay/klipper/bl31.bin /opt/firmware/
    chown -R ${USER}:${USER} klipper
    
    KLIPPER_USER=printer
    PYTHONDIR="${HOMEDIR}/klippy-env"
    SYSTEMDDIR="/etc/systemd/system"
    KLIPPER_GROUP=$KLIPPER_USER
    SRCDIR=${HOMEDIR}/klipper
    KLIPPER_CONFIG=${HOMEDIR}/printer_data/config/printer.cfg
    KLIPPER_LOG=/var/log/klipper_logs/klippy.log
    KLIPPER_SOCKET=/tmp/klippy_uds

    # Trixie optimized package list
    PKGLIST="python3-venv python3-dev libffi-dev build-essential python3-cffi"
    # pkg-config is not optional: lib/rp2040_flash's Makefile gets its libusb
    # include path only from `pkg-config libusb-1.0 --cflags`. Without it the
    # backticks expand to nothing and the build dies on <libusb.h>, even though
    # libusb-1.0-0-dev is installed - the header is under /usr/include/libusb-1.0.
    # A booted Recore has pkg-config, which is why building it by hand there
    # succeeds and the image build does not.
    PKGLIST="${PKGLIST} libncurses-dev libusb-1.0-0-dev stm32flash pkg-config"
    PKGLIST="${PKGLIST} gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi"
    # In Trixie, use the system numpy for speed
    PKGLIST="${PKGLIST} python3-matplotlib"

    # Install desired packages
    apt install --yes ${PKGLIST} --no-install-suggests 
    
    python3 -m venv "${PYTHONDIR}"

    # Install/update dependencies
    ${PYTHONDIR}/bin/pip install -r ${HOMEDIR}/klipper/scripts/klippy-requirements.txt
    ${PYTHONDIR}/bin/pip install numpy

    # Create systemd service file
    cat > /etc/systemd/system/klipper.service << EOF
#Systemd service file for klipper
[Unit]
Description=Starts klipper on startup
After=network.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
User=$KLIPPER_USER
Group=$KLIPPER_GROUP
RemainAfterExit=yes
PermissionsStartOnly=true
ExecStartPre=/usr/bin/gpioset -c 1 -t0 197=0
ExecStartPre=/usr/bin/gpioset -c 1 -t0 196=0
ExecStartPre=/usr/bin/gpioget -c 1 -b pull-up 196
ExecStartPre=/usr/local/bin/set-ar100-clock.py
ExecStartPre=/usr/local/bin/flash-ar100.py /opt/firmware/ar100.bin
ExecStart=${PYTHONDIR}/bin/python ${SRCDIR}/klippy/klippy.py ${KLIPPER_CONFIG} -l ${KLIPPER_LOG} -a ${KLIPPER_SOCKET}
EOF
# Use systemctl to enable the klipper systemd service script
    sudo systemctl enable klipper.service
    
    # Install AR100 toolchain
    wget http://feeds.iagent.no/toolchains/or1k-elf-15.1.0-20260131.tar.xz -P /opt
    cd /opt
    tar -xf /opt/or1k-elf-15.1.0-20260131.tar.xz
    rm /opt/or1k-elf-15.1.0-20260131.tar.xz
    export PATH=$PATH:/opt/or1k-elf/bin
    echo "export PATH=\$PATH:$PATH:/opt/or1k-elf/bin" >> ${HOMEDIR}/.bashrc
    echo "export PATH=\$PATH:$PATH:/opt/or1k-elf/bin" >> /home/debian/.bashrc
    
    # Compile AR100
    cp /tmp/overlay/klipper/ar100.config ${HOMEDIR}/klipper/.config
    cd ${HOMEDIR}/klipper/
    sed -i 's/CFLAGS.*+= -O3//' src/ar100/Makefile

    sed -i 's|ASSERT(. <= (SRAM_A2_SIZE), "Klipper image is too large")|ASSERT(. <= (ORIGIN(SRAM_A2) + LENGTH(SRAM_A2)), "Klipper image is too large")|' src/ar100/ar100.ld

    make olddefconfig
    make -j
    cp ${HOMEDIR}/klipper/out/ar100.bin /opt/firmware
    # flash-ar100.py mmaps /opt/firmware/ar100.bin's target region as
    # Device memory (it's not in /proc/iomem), which requires aligned
    # accesses. Pad to a 16-byte boundary so the bulk write never ends
    # on a misaligned tail store, which would fault with SIGBUS.
    truncate -s %16 /opt/firmware/ar100.bin

    # Compile STM32
    cp /tmp/overlay/klipper/stm32f031-serial.config ${HOMEDIR}/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp ${HOMEDIR}/klipper/out/klipper.bin /opt/firmware/stm32.bin

    # Compile STM32-32KB
    cp /tmp/overlay/klipper/stm32f031-32KB-serial.config ${HOMEDIR}/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp ${HOMEDIR}/klipper/out/klipper.bin /opt/firmware/stm32-32KB.bin

    # Compile RP2040 - ReTool A2, and Remote when it lands (#38).
    #
    # Upstream's own config rather than one of ours: it is two lines
    # (MACH_RPXXXX + MACH_RP2040) and olddefconfig's defaults are already what
    # this board needs - USB rather than UART, and VID:PID 1d50:614e, which is
    # how a flashed board identifies itself.
    #
    # Note the artefact is klipper.uf2, not klipper.bin like the STM32 builds.
    cp ${HOMEDIR}/klipper/test/configs/rp2040.config ${HOMEDIR}/klipper/.config
    make clean
    make olddefconfig
    make -j
    cp ${HOMEDIR}/klipper/out/klipper.uf2 /opt/firmware/rp2040.uf2

    # ...and the flashing tool, which the firmware target does not build. It
    # talks PICOBOOT over libusb (libusb-1.0-0-dev is already in PKGLIST above),
    # so no block device has to be found and mounted - which matters because
    # /dev/sda on these boards is just as likely to be a user's USB stick as the
    # RP2 bootloader drive.
    make -C ${HOMEDIR}/klipper/lib/rp2040_flash
    cp ${HOMEDIR}/klipper/lib/rp2040_flash/rp2040_flash /usr/local/bin/
    chmod +x /usr/local/bin/rp2040_flash
    
    # Revert the patch to get rid of the warning
    git reset --hard

    chown -R ${USER}:${USER} ${HOMEDIR}/klipper
    chown -R ${USER}:${USER} ${PYTHONDIR}

    if [ "${UI}" != "" ]; then
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a5.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a6.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a7.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a8.cfg
    fi
}
