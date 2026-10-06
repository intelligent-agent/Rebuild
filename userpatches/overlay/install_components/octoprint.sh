#!/bin/bash

install_octoprint(){
	echo "🍰 install OctoPrint"
	cd ${HOMEDIR}
	apt-get install -y python3 python3-pip python3-dev python3-setuptools python3-venv git libyaml-dev build-essential libffi-dev libssl-dev nftables python3-libxml2
	mkdir OctoPrint
	cd OctoPrint
	python3 -m venv venv
	source venv/bin/activate
	pip install --upgrade pip wheel
	pip install "octoprint==${OCTOPRINT_VERSION}"
	cp /tmp/overlay/octoprint/octoprint.service /etc/systemd/system/octoprint.service
	systemctl enable octoprint
	mkdir -p ${HOMEDIR}/.octoprint
	cp /tmp/overlay/octoprint/config.yaml ${HOMEDIR}/.octoprint/
	chown -R ${USER}:${USER} ${HOMEDIR}/.octoprint/
	chown -R ${USER}:${USER} ${HOMEDIR}/OctoPrint
	deactivate

	# nftables
	cp /tmp/overlay/octoprint/nftables.conf /etc/
	systemctl enable nftables
	echo "octoprint 5000/tcp" >> /etc/services

	echo '%printer ALL=NOPASSWD: /usr/sbin/reboot' >> /etc/sudoers.d/printer
	echo '%printer ALL=NOPASSWD: /usr/sbin/shutdown -h now' >> /etc/sudoers.d/printer
	echo '%printer ALL=NOPASSWD: /usr/bin/systemctl restart octoprint.service' >> /etc/sudoers.d/printer
	echo '%printer ALL=NOPASSWD: /usr/bin/systemctl restart toggle.service' >> /etc/sudoers.d/printer

	# Install plugins. Without build isolation: their setup.py imports
	# OctoPrint's own setuptools helpers, which only this venv has.
	cd ${HOMEDIR}
	git clone https://github.com/thelastWallE/OctoprintKlipperPlugin.git
	git -C OctoprintKlipperPlugin reset --hard "${OCTOPRINT_KLIPPER_PLUGIN_VERSION}"
	chown -R ${USER}:${USER} OctoprintKlipperPlugin
	${HOMEDIR}/OctoPrint/venv/bin/pip install --no-build-isolation ./OctoprintKlipperPlugin
	
	cd ${HOMEDIR}
	git clone https://github.com/LazeMSS/OctoPrint-TopTemp.git
	git -C OctoPrint-TopTemp reset --hard "${OCTOPRINT_TOPTEMP_VERSION}"
	chown -R ${USER}:${USER} OctoPrint-TopTemp
	${HOMEDIR}/OctoPrint/venv/bin/pip install --no-build-isolation ./OctoPrint-TopTemp

	cd ${HOMEDIR}
	git clone https://github.com/intelligent-agent/octoprint_recore.git
	git -C octoprint_recore reset --hard "${OCTOPRINT_RECORE_REVISION}"
	chown -R ${USER}:${USER} octoprint_recore
	${HOMEDIR}/OctoPrint/venv/bin/pip install --no-build-isolation ./octoprint_recore

	# The plugins went in as root, after the chown above: hand the venv to the
	# user OctoPrint runs as, or its own updates cannot remove the old version
	# and offer the same update again and again. pip, not a setuptools egg, so
	# each plugin is a dist-info that pip can uninstall cleanly.
	chown -R ${USER}:${USER} ${HOMEDIR}/OctoPrint ${HOMEDIR}/OctoprintKlipperPlugin \
		${HOMEDIR}/OctoPrint-TopTemp ${HOMEDIR}/octoprint_recore
}

install_octodash() {
	cd ${HOMEDIR}
	apt-get install -y libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 \
	libuuid1 libappindicator3-1 libsecret-1-0 xserver-xorg ratpoison x11-xserver-utils xinit \
	libgtk-3-0 bc desktop-file-utils libavahi-compat-libdnssd1 libpam0g-dev libx11-dev
	wget "https://github.com/UnchartedBull/OctoDash/releases/download/${OCTODASH_VERSION}/octodash_${OCTODASH_VERSION#v}_arm64.deb"
	dpkg -i "octodash_${OCTODASH_VERSION#v}_arm64.deb"
	${HOMEDIR}/OctoPrint/venv/bin/octoprint config set --bool "api.allowCrossOrigin" true
	cp /tmp/overlay/octodash/octodash.service /etc/systemd/system/
	systemctl enable octodash
}
