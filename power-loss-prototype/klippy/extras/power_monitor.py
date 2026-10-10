# Power-loss detection prototype (Rebuild#140)
#
# Configures src/power_monitor.c on the MCU that measures the input voltage:
# it samples sensor_pin every sample_us, and below `threshold` volts drives
# int_pin high and then toggles it every heartbeat_ms until it loses power.
#
#   [power_monitor]
#   sensor_pin: PA4      # the input voltage, as [temperature_sensor voltage]
#   int_pin: PF1         # UC-INT-1, to the A64's PG3
#   threshold: 20
#
# The pin is shared with the voltage sensor, so it is parsed, not claimed.
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging

class PowerMonitor:
    def __init__(self, config):
        self.printer = config.get_printer()
        ppins = self.printer.lookup_object('pins')
        sensor = ppins.parse_pin(config.get('sensor_pin'))
        intpin = ppins.parse_pin(config.get('int_pin'))
        if sensor['chip_name'] != intpin['chip_name']:
            raise config.error("power_monitor: sensor_pin and int_pin must be"
                               " on the same MCU")
        self.mcu = ppins.chips[sensor['chip_name']]
        self.sensor_pin, self.int_pin = sensor['pin'], intpin['pin']
        self.threshold = config.getfloat('threshold', 20., above=0.)
        # Vin = divider * Vadc + offset: the voltage sensor's adc_temperature
        # table in generic-recore-a*.cfg (0 V -> 0.35, 3.3 V -> 36.65).
        self.divider = config.getfloat('divider', 11., above=0.)
        self.offset = config.getfloat('offset', 0.35)
        self.adc_voltage = config.getfloat('adc_voltage', 3.3, above=0.)
        self.sample_us = config.getint('sample_us', 100, minval=20)
        self.heartbeat_ms = config.getfloat('heartbeat_ms', 1., above=0.)
        self.adc_max = None
        self.trip = None
        self.oid = self.mcu.create_oid()
        self.mcu.register_config_callback(self._build_config)
        self.query_cmd = None
        self.printer.lookup_object('gcode').register_command(
            'POWER_MONITOR_QUERY', self.cmd_QUERY,
            desc="What the power monitor last sampled")
        self.mcu.register_serial_response(
            self._handle_trip,
            "power_monitor_tripped oid=%c clock=%u value=%hu", self.oid)

    def _build_config(self):
        self.adc_max = self.mcu.get_constant_float("ADC_MAX")
        vadc = (self.threshold - self.offset) / self.divider
        raw = max(0, min(int(vadc / self.adc_voltage * self.adc_max),
                         int(self.adc_max)))
        self.mcu.add_config_cmd(
            "config_power_monitor oid=%d adc_pin=%s int_pin=%s threshold=%d"
            " rest_ticks=%d heartbeat_ticks=%d" % (
                self.oid, self.sensor_pin, self.int_pin, raw,
                self.mcu.seconds_to_clock(self.sample_us / 1000000.),
                self.mcu.seconds_to_clock(self.heartbeat_ms / 1000.)))
        self.query_cmd = self.mcu.lookup_query_command(
            "power_monitor_query oid=%c",
            "power_monitor_state oid=%c value=%hu samples=%u tripped=%c",
            oid=self.oid)
        logging.info("power_monitor: %s below %.1f V (raw %d), every %d us,"
                     " signalled on %s", self.sensor_pin, self.threshold, raw,
                     self.sample_us, self.int_pin)

    def _handle_trip(self, params):
        clock = self.mcu.clock32_to_clock64(params['clock'])
        print_time = self.mcu.clock_to_print_time(clock)
        volts = (params['value'] / self.adc_max * self.adc_voltage
                 * self.divider + self.offset)
        self.trip = {'print_time': print_time, 'voltage': volts}
        msg = ("power_monitor: input %.2f V, below %.1f V, at print_time %.4f"
               % (volts, self.threshold, print_time))
        logging.warning(msg)
        self.printer.lookup_object('gcode').respond_info(msg)

    def cmd_QUERY(self, gcmd):
        r = self.query_cmd.send([self.oid])
        volts = (r['value'] / self.adc_max * self.adc_voltage * self.divider
                 + self.offset)
        gcmd.respond_info("power_monitor: last sample %d (%.2f V), %d samples,"
                          " tripped=%d" % (r['value'], volts, r['samples'],
                                           r['tripped']))

    def get_status(self, eventtime):
        return {'tripped': self.trip is not None, 'trip': self.trip}

def load_config(config):
    return PowerMonitor(config)
