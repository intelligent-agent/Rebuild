#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# This is the image customization script

# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed

# NOTE: If you want to transfer files between chroot and host
# userpatches/overlay directory on host is bind-mounted to /tmp/overlay in chroot
# The sd card's root path is accessible via $SDCARD variable.

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4


install_klipper(){
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

	mkdir -p  /home/debian/printer_data/config/
	chown -R debian:debian /home/debian/printer_data/
}

install_octoprint(){
	cd /home/debian
	apt install -y python3 python3-pip python3-dev python3-setuptools python3-venv git libyaml-dev build-essential libffi-dev libssl-dev nftables
	mkdir OctoPrint
	cd OctoPrint
	python3 -m venv venv
	source venv/bin/activate
	python -m venv OctoPrint
	pip install --upgrade pip wheel
	pip install octoprint
	cp /tmp/overlay/octoprint/octoprint.service /etc/systemd/system/octoprint.service
	chown -R debian:debian OctoPrint
	systemctl enable octoprint
    mkdir -p /home/debian/.octoprint
	cp /tmp/overlay/octoprint/config.yaml /home/debian/.octoprint/
    chown -R debian:debian /home/debian/.octoprint/

	# nftables
	cp /tmp/overlay/octoprint/nftables.conf /etc/
	systemctl enable nftables
	echo "octoprint 5000/tcp" >> /etc/services

	# Install plugins
	cd /home/debian
	git clone https://github.com/thelastWallE/OctoprintKlipperPlugin.git
	cd OctoprintKlipperPlugin
	/home/debian/OctoPrint/venv/bin/python setup.py install

	cd /home/debian
	git clone https://github.com/LazeMSS/OctoPrint-TopTemp.git
	cd OctoPrint-TopTemp
	/home/debian/OctoPrint/venv/bin/python setup.py install

	cd /home/debian
	git clone https://github.com/intelligent-agent/octoprint_refactor.git
	cd octoprint_refactor/
	/home/debian/OctoPrint/venv/bin/python setup.py install
}

install_octodash() {
	cd /home/debian
	apt install libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 \
	libuuid1 libappindicator3-1 libsecret-1-0 xserver-xorg ratpoison x11-xserver-utils xinit \
	libgtk-3-0 bc desktop-file-utils libavahi-compat-libdnssd1 libpam0g-dev libx11-dev
	wget https://github.com/UnchartedBull/OctoDash/releases/download/v2.3.1/octodash_2.3.1_arm64.deb
	dpkg -i octodash_2.3.1_arm64.deb
	/home/debian/OctoPrint/venv/bin/octoprint config set --bool "api.allowCrossOrigin" true
	cp /tmp/overlay/octodash/octodash.service /etc/systemd/system/
	systemctl enable octodash
}

install_bins(){
    cp /tmp/overlay/bins/* /usr/local/bin
    chmod +x /usr/local/bin/*
}

install_ustreamer() {
    cd /home/debian
    apt install -y build-essential libevent-dev libjpeg-dev libbsd-dev
    git clone https://github.com/pikvm/ustreamer
    cd /home/debian/ustreamer
    make -j
    echo 'SUBSYSTEM=="video4linux", ATTR{name}!="cedrus", ATTR{index}=="0", SYMLINK+="webcam", TAG+="systemd"' > /etc/udev/rules.d/50-video.rules
    echo '%debian ALL=NOPASSWD: /bin/systemctl restart ustreamer.service' >> /etc/sudoers.d/debian
    cp /tmp/overlay/ustreamer/ustreamer.service /etc/systemd/system/
	systemctl enable ustreamer
}

install_autohotspot() {
    # Install autohotspot script
    cp /tmp/overlay/autohotspot/autohotspot /usr/local/bin
    chmod +x /usr/local/bin/autohotspot

    # Install autohotspot service file
    cp /tmp/overlay/autohotspot/autohotspot.service /etc/systemd/system/

    systemctl enable autohotspot.service
}


prepare_build() {
    apt update
    apt install -y avahi-daemon git iptables dnsmasq-base

    # Ensure the debian user exists
    useradd debian -d /home/debian -G tty,dialout -m -s /bin/bash -e -1
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian

    # Set default passwords
    echo debian:temppwd | chpasswd
    echo root:temppwd | chpasswd

    # Remove "dubious ownership" message when running git commands
    git config --global --add safe.directory '*'

    # Disable SSH root access
    sed -i 's/^PermitRootLogin.*$/#PermitRootLogin/g' /etc/ssh/sshd_config

    # Disable SSH. Can be enabled in Reflash
    systemctl disable ssh

    echo "ttyGS0" >> /etc/securetty
    systemctl enable serial-getty@ttyGS0.service

    cp /tmp/overlay/rebuild/rebuild-version /etc/
    # Backwards compatibility with refactor
    cp /tmp/overlay/rebuild/rebuild-version /etc/refactor.version
}

add_overlays(){
    mkdir /boot/overlay-user
    cp /tmp/overlay/dts/* /boot/overlay-user
}

fix_netplan(){
    cat <<- EOF > /etc/netplan/armbian-default.yaml
		network:
		  version: 2
		  renderer: NetworkManager
	EOF
}

post_build() {
    echo "🍰 Post build"
    # Force debian to change password
    chage -d 0 debian
}

set -e

echo "🍰 Rebuild starting..."

prepare_build
install_klipper
install_octoprint
install_ustreamer
install_bins
install_autohotspot
add_overlays
fix_netplan
post_build

echo "🍰 Rebuild finished"
