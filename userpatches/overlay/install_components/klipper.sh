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
    PKGLIST="${PKGLIST} libncurses-dev libusb-1.0-0-dev stm32flash"
    PKGLIST="${PKGLIST} gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi"
    # In Trixie, use the system numpy for speed
    PKGLIST="${PKGLIST} python3-numpy python3-matplotlib"

    # Install desired packages
    apt install --yes ${PKGLIST} --no-install-suggests 
    
    python3 -m venv "${PYTHONDIR}"

    # Install/update dependencies
    ${PYTHONDIR}/bin/pip install -r ${HOMEDIR}/klipper/scripts/klippy-requirements.txt
        
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
ExecStartPre=${SRCDIR}/scripts/flash-ar100.py /opt/firmware/ar100.bin
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
