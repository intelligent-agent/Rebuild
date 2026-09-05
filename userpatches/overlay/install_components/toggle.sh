#!/bin/bash

install_weston(){
	echo "🍰 installing Weston"
	cd ${HOMEDIR}
	# This pulls in a lot of packages, should be optimized
	apt install -y weston librsvg2-common libgl1-mesa-dri

	mkdir -p /etc/xdg/weston/
	cat > /etc/xdg/weston/weston.ini <<EOF
[core]
idle-time=0

[shell]
locking=false
panel-position=none

[output]
name=HDMI-A-1
transform=normal

# The panel is driven by simpledrm off the framebuffer u-boot hands over, and
# simpledrm reports DRM_MODE_CONNECTOR_Unknown, so the output is Unknown-1 and
# not HDMI-A-1. Both sections are kept: weston applies whichever one matches
# the connector actually present, so this still works on an image built before
# the switch to simpledrm.
[output]
name=Unknown-1
transform=normal
EOF

	cat > /etc/systemd/system/weston.service <<EOF
[Unit]
Description=Weston Wayland Compositor
After=plymouth-quit-wait.service

[Service]
Environment="XDG_RUNTIME_DIR=/tmp"
ExecStart=/usr/bin/weston

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable weston
}

install_toggle(){
    echo "🍰 installing Toggle"
    apt install -y gir1.2-clutter-1.0 python3-gi-cairo
    wget http://feeds.iagent.no/debian/pool/main/libmx-2.0-0_2.0-1_arm64.deb
    wget http://feeds.iagent.no/debian/pool/main/libmash-0.3-0_0.3.0-1_arm64.deb
    wget http://feeds.iagent.no/debian/pool/main/gir1.2-mash-0.3-0_0.3.0-1_arm64.deb
    wget http://feeds.iagent.no/debian/pool/main/gir1.2-mx-2.0-0_2.0-1_arm64.deb
    dpkg -i libmx-2.0-0_2.0-1_arm64.deb
    dpkg -i libmash-0.3-0_0.3.0-1_arm64.deb
    dpkg -i gir1.2-mx-2.0-0_2.0-1_arm64.deb
    dpkg -i gir1.2-mash-0.3-0_0.3.0-1_arm64.deb
    rm -rf *.deb

    apt-get install -y pkg-config libdbus-1-dev libglib2.0-dev

    cd ${HOMEDIR}
    git clone https://github.com/intelligent-agent/toggle
    cd toggle
    pip3 install -r requirements.txt --break-system-packages
    python3 ./install_data.py

    cat > /etc/systemd/system/toggle.service <<EOF
[Unit]
Description=3D-printer user interface
After=weston.service
Requires=weston.service
StartLimitIntervalSec=5
StartLimitBurst=3

[Service]
Environment="XDG_RUNTIME_DIR=/tmp"
Environment="WAYLAND_DISPLAY=wayland-1"
Environment=MX_RC_FILE=/etc/toggle/styles/Plain/style.css
ExecStart=/usr/local/bin/toggle
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/toggle/local.cfg <<EOF
[OctoPrint]
user = toggle
authentication =
EOF

    chown -R ${USER}:${USER} ${HOMEDIR}/toggle
    chown -R ${USER}:${USER} /etc/toggle
    systemctl enable toggle

    cd ${HOMEDIR}
    git clone https://github.com/intelligent-agent/octoprint_toggle
    cd octoprint_toggle
    ${HOMEDIR}/OctoPrint/venv/bin/python setup.py install

    # A path unit rather than a poll loop.
    #
    # toggle-runfirst can only do its work once OctoPrint's setup wizard has
    # created users.yaml, which may be minutes or never. It used to wait by
    # sleeping a second at a time in a resident Python process; systemd watches
    # the path with inotify and starts the job when the file appears.
    cat > /etc/systemd/system/toggle-runfirst.path <<EOF
[Unit]
Description=Wait for OctoPrint to have a user before registering Toggle

[Path]
PathExists=/home/printer/.octoprint/users.yaml
Unit=toggle-runfirst.service

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/toggle-runfirst.service <<EOF
[Unit]
Description=Allow Toggle to register access to OctoPrint

# ConditionPathExists=! makes a second run a no-op even if the path unit is
# somehow still armed - PathExists= re-triggers as soon as the service exits
# while the file is still there, so the service has to be the thing that stops
# being runnable.
ConditionPathExists=!/var/lib/toggle-runfirst.done

[Service]
# oneshot, not simple: it does its work and exits. Started by
# toggle-runfirst.path, which is what waits.
Type=oneshot
ExecStart=/usr/lib/toggle-runfirst
EOF
    cp /tmp/overlay/toggle/toggle-runfirst /usr/lib
    chmod +x /usr/lib/toggle-runfirst
    # The path unit is what gets enabled; it starts the service.
    systemctl enable toggle-runfirst.path
}
