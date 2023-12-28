#!/bin/bash

install_octoprint(){
	echo "🍰 install OctoPrint"
	cd /home/debian
	apt install -y python3 python3-pip python3-dev python3-setuptools python3-venv git libyaml-dev build-essential libffi-dev libssl-dev nftables
	mkdir OctoPrint
	cd OctoPrint
	python3 -m venv venv
	source venv/bin/activate
	pip install --upgrade pip wheel
	pip install octoprint
	cp /tmp/overlay/octoprint/octoprint.service /etc/systemd/system/octoprint.service
	systemctl enable octoprint
    mkdir -p /home/debian/.octoprint
	cp /tmp/overlay/octoprint/config.yaml /home/debian/.octoprint/
    chown -R debian:debian /home/debian/.octoprint/
	chown -R debian:debian /home/debian/OctoPrint
	deactivate

	# nftables
	cp /tmp/overlay/octoprint/nftables.conf /etc/
	systemctl enable nftables
	echo "octoprint 5000/tcp" >> /etc/services

	# Install plugins
	cd /home/debian
	git clone https://github.com/thelastWallE/OctoprintKlipperPlugin.git
	chown -R debian:debian /home/debian/OctoprintKlipperPlugin
	cd OctoprintKlipperPlugin
	/home/debian/OctoPrint/venv/bin/python setup.py install
	

	cd /home/debian
	git clone https://github.com/LazeMSS/OctoPrint-TopTemp.git
	chown -R debian:debian /home/debian/OctoPrint-TopTemp
	cd OctoPrint-TopTemp
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
