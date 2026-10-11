# Expose Recore's existing Klipper ADC reading through Moonraker's sensor API.
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
import math

from .sensor import BaseSensor


class RecoreVoltage(BaseSensor):
    def __init__(self, config):
        super().__init__(config)
        self.configured_source = config.get("klipper_object", None)
        self.source = self.configured_source
        self.connected = False
        sensors = self.server.load_component(config, "sensor")
        if self.id in sensors.sensors:
            raise config.error(f"Sensor '{self.id}' already exists")
        sensors.sensors[self.id] = self
        # Mainsail 2.19 reads units from /server/config, whereas Fluidd reads
        # parameter_info. Publish the same metadata without adding a disk
        # [sensor ...] section (stock Moonraker only accepts MQTT there).
        config.parsed[f"sensor {self.id}"] = {
            f"parameter_{param['name']}": {
                key: value for key, value in param.items() if key != "name"
            } for param in self.param_info
        }
        self.server.register_event_handler("server:klippy_ready", self.on_ready)
        self.server.register_event_handler("server:status_update", self.on_status)
        self.server.register_event_handler("server:klippy_shutdown", self.clear)
        self.server.register_event_handler("server:klippy_disconnect", self.clear)

    async def on_ready(self):
        self.clear()
        try:
            api = self.server.lookup_component("klippy_apis")
            objects = await api.get_object_list()
            candidates = ([self.configured_source] if self.configured_source else
                          ["temperature_sensor _voltage", "temperature_sensor voltage"])
            self.source = next((obj for obj in candidates if obj in objects), None)
            if self.source is None:
                logging.warning("No Recore input voltage sensor configured in Klipper")
                return
            status = await api.subscribe_objects({self.source: ["temperature"]})
        except Exception:
            logging.exception("Unable to subscribe to Recore input voltage")
            return
        self.connected = True
        self.on_status(status)

    def on_status(self, status, eventtime=None):
        if not self.connected or self.source not in status:
            return
        source = status[self.source]
        if "temperature" not in source:
            return
        value = source["temperature"]
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            self.last_measurements = {"voltage": value}
        else:
            self.last_measurements = {}

    def clear(self):
        self.connected = False
        self.last_measurements = {}
        self.values.clear()


def load_component(config):
    return RecoreVoltage(config)
