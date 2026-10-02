# Tell the user in Fluidd and Mainsail when an MCU runs firmware from another
# Klipper version than the host (#106)
#
# Copyright (C) 2026  Elias Bakken <elias@iagent.no>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging, re

# An MCU reports the git describe of the tree it was built from, then the
# build time and host: v0.13.0-786-g461c4e37-20261001_212932-1944db0ac369
BUILD_SUFFIX = re.compile(r'-\d{8}_\d{6}-[^-]+$')

def commit(version):
    # Klipper calls itself -dirty whenever klippy/extras holds an untracked
    # module - ours, linked by klipper-extras, or a user's - so compare the
    # commits only.
    version = BUILD_SUFFIX.sub('', version)
    return version[:-len('-dirty')] if version.endswith('-dirty') else version

class RebuildFirmware:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.printer.register_event_handler("klippy:ready", self._check)
    def _check(self):
        host = self.printer.get_start_args().get('software_version', '')
        if not host or host == '?':
            return
        stale = []
        for name, mcu in self.printer.lookup_objects('mcu'):
            version = mcu.get_status(0).get('mcu_version', '')
            if version and commit(version) != commit(host):
                stale.append("%s (%s)" % (name.split()[-1], commit(version)))
        if not stale:
            return
        msg = ("Klipper is at %s, but the firmware on %s was"
               " built from a different version. To rebuild it, start"
               " rebuild-firmware under Services (the top-right menu in"
               " Fluidd, the power menu in Mainsail). Klipper restarts when"
               " it is done." % (commit(host), ", ".join(stale)))
        logging.info("rebuild_firmware: %s", msg)
        self.printer.lookup_object('configfile').runtime_warning(msg)

def load_config(config):
    return RebuildFirmware(config)
