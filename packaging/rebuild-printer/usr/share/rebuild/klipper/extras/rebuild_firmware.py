"""Compatibility for existing [rebuild_firmware] config sections.

Firmware version status is now supplied by Moonraker's Klipper firmware
updater. Keep accepting archived printer configs without a runtime warning.
"""


def load_config(config):
    return object()
