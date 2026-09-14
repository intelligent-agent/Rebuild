#!/bin/bash

# Rebuild's application inputs are deliberately explicit.  The image is an
# integration-tested baseline; following each project's default branch or
# "latest" redirect during the build makes the same source revision produce a
# different image and gives CI nothing meaningful to upgrade-test.
#
# Update these only after testing the new versions together.  Tags/releases are
# used where upstream publishes them; the two Recore-specific OctoPrint plugins
# have neither, so their immutable commits are recorded instead.

KLIPPER_VERSION="v0.13.0"
MOONRAKER_VERSION="v0.11.0"
KLIPPERSCREEN_VERSION="v0.4.7"
FLUIDD_VERSION="v1.37.5"
MAINSAIL_VERSION="v2.19.0"
OCTOPRINT_VERSION="1.11.8"
OCTOPRINT_KLIPPER_PLUGIN_VERSION="0.3.9.5"
OCTOPRINT_TOPTEMP_VERSION="0.0.2.5"
OCTODASH_VERSION="v2.8.0"
USTREAMER_VERSION="v6.66"
TOGGLE_VERSION="v1.4.2"
OCTOPRINT_TOGGLE_REVISION="818c43b81edaae4f37d8ff5e34658d63f400d373"
OCTOPRINT_RECORE_REVISION="274184dc129489cd9c09bc3e9539d3a7f317f0e4"

# Leave an auditable record on the installed board as well. It is useful when
# comparing an update-manager result to the image it started from.
record_software_versions() {
    install -Dm644 /tmp/overlay/install_components/software_versions.sh \
        /etc/rebuild-software-versions
}
