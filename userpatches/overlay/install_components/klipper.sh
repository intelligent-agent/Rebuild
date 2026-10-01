#!/bin/bash

install_klipper(){
    UI=$1
    echo "🍰 install Klipper"
    cd "${HOMEDIR}"
    # Blobless, not shallow: Moonraker's update manager needs the full commit
    # and tag history (a --depth 1 clone showed as unknown, Refactor #329),
    # but not every old file version.  Cuts .git from ~250 MB to ~20 MB.
    git clone --filter=blob:none https://github.com/Klipper3d/klipper
    git -C klipper reset --hard "${KLIPPER_VERSION}"

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
    mkdir -p /var/log/klipper_logs
    chown ${USER}:${USER} /var/log/klipper_logs
    mkdir -p /opt/firmware/
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
    # No python3-matplotlib. Klipper never imports it: SHAPER_CALIBRATE needs
    # only numpy, which is pip-installed into klippy-env below. matplotlib is
    # for the optional graph scripts (scripts/calibrate_shaper.py and co.),
    # and with the scipy/sympy it drags in it was 33 packages and 242 MB for
    # an occasional chart. Graphs are drawn on a PC, or after
    # `apt install python3-matplotlib` on the printer - see the release notes.

    # Install desired packages
    apt-get install --yes ${PKGLIST} --no-install-suggests 
    
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
ExecStartPre=/usr/bin/set-ar100-clock.py
ExecStartPre=/usr/bin/flash-ar100.py /opt/firmware/ar100.bin
ExecStart=${PYTHONDIR}/bin/python ${SRCDIR}/klippy/klippy.py ${KLIPPER_CONFIG} -l ${KLIPPER_LOG} -a ${KLIPPER_SOCKET}
EOF
# Use systemctl to enable the klipper systemd service script
    sudo systemctl enable klipper.service
    
    # Install AR100 toolchain
    # GCC 16.1.0 with the 2026-06 OpenRISC codegen fixes (64- and 16-bit
    # shifts, branch placement), built from stffrdhrn/or1k-toolchain-build
    # for aarch64, C only, stripped: 93 MB installed.
    OR1K_TOOLCHAIN=or1k-elf-16.1.0-20260930.tar.xz
    wget http://feeds.iagent.no/toolchains/${OR1K_TOOLCHAIN} -P /opt
    cd /opt
    tar -xf /opt/${OR1K_TOOLCHAIN}
    rm /opt/${OR1K_TOOLCHAIN}
    export PATH=$PATH:/opt/or1k-elf/bin
    echo "export PATH=\$PATH:$PATH:/opt/or1k-elf/bin" >> ${HOMEDIR}/.bashrc
    echo "export PATH=\$PATH:$PATH:/opt/or1k-elf/bin" >> /home/debian/.bashrc
    
    # The firmware, with the same tool and stock configs a board rebuilds it
    # with after a Klipper update (#106): every STM32 variant, since there is
    # no board here to ask which one it has. It builds in its own copy of the
    # checkout, so the checkout stays unmodified for Moonraker.
    rebuild-firmware build --all-variants
    rm -rf /var/lib/rebuild/firmware

    # ...and the flashing tool, which the firmware target does not build. It
    # talks PICOBOOT over libusb (libusb-1.0-0-dev is already in PKGLIST above),
    # so no block device has to be found and mounted - which matters because
    # /dev/sda on these boards is just as likely to be a user's USB stick as the
    # RP2 bootloader drive.
    make -C ${HOMEDIR}/klipper/lib/rp2040_flash
    cp ${HOMEDIR}/klipper/lib/rp2040_flash/rp2040_flash /usr/local/bin/
    chmod +x /usr/local/bin/rp2040_flash
    
    chown -R ${USER}:${USER} ${HOMEDIR}/klipper
    chown -R ${USER}:${USER} ${PYTHONDIR}

    if [ "${UI}" != "" ]; then
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a5.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a6.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a7.cfg
        sed -i 's:\(\# See docs.*\):\1\n\n\[include '${UI}'.cfg\]:' ${HOMEDIR}/klipper/config/generic-recore-a8.cfg
    fi
}
