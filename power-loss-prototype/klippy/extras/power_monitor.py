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
import hashlib
import json
import os
from pathlib import Path
import struct
import zlib

class PowerMonitor:
    def __init__(self, config):
        self.printer = config.get_printer()
        ppins = self.printer.lookup_object('pins')
        sensor = ppins.parse_pin(config.get('sensor_pin'))
        intpin = ppins.lookup_pin(config.get('int_pin'))
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
        self.required_samples = config.getint('required_samples', 3, minval=1,
                                              maxval=255)
        self.heartbeat_ms = config.getfloat('heartbeat_ms', 1., above=0.)
        self.adc_max = None
        self.trip = None
        self.recovery = None
        self.stream_sequence = None
        self.stream_timer = None
        self.reactor = self.printer.get_reactor()
        self.recovery_dir = Path(config.get('recovery_directory',
            '/home/printer/printer_data/recovery-demo'))
        self.printer.lookup_object('gcode').register_command(
            'RECOVERY_DEMO_START', self.cmd_RECOVERY_START)
        self.printer.lookup_object('gcode').register_command(
            'RECOVERY_DEMO_QUERY', self.cmd_RECOVERY_QUERY)
        self.printer.lookup_object('gcode').register_command(
            'RECOVERY_DEMO_HANDOFF', self.cmd_RECOVERY_HANDOFF)
        self.printer.lookup_object('gcode').register_command(
            'RECOVERY_DEMO_CONSUME', self.cmd_RECOVERY_CONSUME)
        self.emergency_shutdown = config.getboolean('emergency_shutdown', False)
        self.oid = self.mcu.create_oid()
        self.mcu.register_config_callback(self._build_config)
        self.query_cmd = None
        self.arm_cmd = None
        self.printer.register_event_handler('klippy:ready', self._arm)
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
            " rest_ticks=%d heartbeat_ticks=%d required_samples=%d" % (
                self.oid, self.sensor_pin, self.int_pin, raw,
                self.mcu.seconds_to_clock(self.sample_us / 1000000.),
                self.mcu.seconds_to_clock(self.heartbeat_ms / 1000.),
                self.required_samples))
        self.arm_cmd = self.mcu.lookup_command("power_monitor_arm oid=%c")
        self.recovery_batch = self.mcu.lookup_command(
            'recovery_batch clock=%u period=%u sequence=%u data=%*s')
        self.recovery_run = self.mcu.lookup_command('recovery_run run=%u')
        self.recovery_consume = self.mcu.lookup_command('recovery_consume run=%u')
        self.recovery_query = self.mcu.lookup_query_command('recovery_query',
            'recovery_record pending=%c saved=%c applied=%u dropped=%u data=%*s')
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
        self.stream_sequence = None
        msg = ("power_monitor: input %.2f V, below %.1f V, at print_time %.4f"
               % (volts, self.threshold, print_time))
        logging.warning(msg)
        self.printer.lookup_object('gcode').respond_info(msg)
        if self.emergency_shutdown:
            self.printer.invoke_async_shutdown(msg)

    def _arm(self):
        # Query commands can yield; ready callbacks explicitly forbid that.
        self.reactor.register_callback(self._arm_deferred)

    def _arm_deferred(self, eventtime):
        # Config/driver initialization can briefly disturb the rail. Begin
        # protection once Klipper is ready, before accepting a print job.
        self.recovery = self._read_recovery()
        if self.recovery['pending']:
            logging.warning('Pending STM32 recovery record: detector left disarmed')
        else:
            self.arm_cmd.send([self.oid])

    def cmd_QUERY(self, gcmd):
        r = self.query_cmd.send([self.oid])
        volts = (r['value'] / self.adc_max * self.adc_voltage * self.divider
                 + self.offset)
        gcmd.respond_info("power_monitor: last sample %d (%.2f V), %d samples,"
                          " tripped=%d" % (r['value'], volts, r['samples'],
                                           r['tripped']))

    def get_status(self, eventtime):
        return {'tripped': self.trip is not None, 'trip': self.trip, 'recovery': self.recovery, 'stream_sequence': self.stream_sequence}

    @staticmethod
    def sample(sequence):
        return [sequence % 200 * 100, -(sequence % 1000) * 17,
                10000 + sequence % 100, sequence % 1000 * 5]

    @staticmethod
    def _durable(path, record):
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix('.tmp')
        with temp.open('w') as f:
            json.dump(record, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(str(temp), str(path))
        fd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _read_recovery(self):
        response = self.recovery_query.send([])
        result = {k:response[k] for k in ('pending', 'saved', 'applied', 'dropped')}
        if not result['pending']:
            return result
        raw = bytes(response['data'])
        if len(raw) != 44:
            raise self.printer.command_error('Invalid recovery record length')
        fields = struct.unpack('<5I4iIHH', raw)
        if fields[0] != 0x31524c50 or fields[-2] != 0xa55a or fields[-1] != 0xffff:
            raise self.printer.command_error('Invalid recovery header')
        if zlib.crc32(raw[:36]) != fields[9]:
            raise self.printer.command_error('Invalid recovery CRC')
        result.update(run=fields[1], sequence=fields[2], sample_clock=fields[3],
                      trip_clock=fields[4], xyze_um=list(fields[5:9]), crc=fields[9])
        return result

    def cmd_RECOVERY_START(self, gcmd):
        if self.trip or self.stream_sequence is not None or self._read_recovery()['pending']:
            raise gcmd.error('Restart/hand off recovery before starting a new experiment')
        self.run = gcmd.get_int('RUN', minval=1, maxval=0x7fffffff)
        interval = gcmd.get_float('INTERVAL_MS', 1., minval=1., maxval=10.) / 1000.
        filename = gcmd.get('FILENAME', '')
        if filename:
            base = Path(self.printer.lookup_object('virtual_sdcard').sdcard_dirname)
            target = (base / filename).resolve()
            if base.resolve() not in target.parents:
                raise gcmd.error('Invalid fixture filename')
            file_hash = hashlib.sha256(target.read_bytes()).hexdigest()
            # A saved restart pointer is useless if a newly uploaded file is
            # still only in page cache. Establish durability before arming.
            with target.open('rb') as f:
                os.fsync(f.fileno())
            fd = os.open(str(target.parent), os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        else:
            file_hash = None
        self.period = self.mcu.seconds_to_clock(interval)
        self.interval = interval
        now = self.reactor.monotonic()
        self.begin_clock = self.mcu.print_time_to_clock(
            self.mcu.estimated_print_time(now) + .020)
        context = dict(version=1, run=self.run, synthetic=True,
                       filename=filename, sha256=file_hash,
                       interval=interval,
                       period_ticks=self.period, sample_formula='PowerMonitor.sample(sequence)',
                       boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
        self._durable(self.recovery_dir / ('%08x-context.json' % self.run), context)
        # Disk flush may take time; establish the timeline after it completes.
        now = self.reactor.monotonic()
        self.begin_clock = self.mcu.print_time_to_clock(
            self.mcu.estimated_print_time(now) + .020)
        self.recovery_run.send([self.run])
        self.stream_sequence = 0
        self.stream_origin = now
        self.stream_timer = self.reactor.register_timer(self._stream, now)
        gcmd.respond_info('Synthetic recovery stream armed: run=%d interval=%gms' %
                          (self.run, interval*1000))

    def _stream(self, eventtime):
        if self.stream_sequence is None or self.trip:
            return self.reactor.NEVER
        sequence = self.stream_sequence
        data = b''.join(struct.pack('<4h', *self.sample(sequence+i)) for i in range(4))
        clock = (self.begin_clock + sequence*self.period) & 0xffffffff
        self.recovery_batch.send([clock, self.period, sequence, data], reqclock=clock)
        self.stream_sequence += 4
        return self.stream_origin + self.stream_sequence*self.interval

    def cmd_RECOVERY_QUERY(self, gcmd):
        self.recovery = self._read_recovery()
        gcmd.respond_info(json.dumps(self.recovery))

    def cmd_RECOVERY_HANDOFF(self, gcmd):
        self.recovery = self._read_recovery()
        if not self.recovery['pending']:
            raise gcmd.error('No pending recovery record')
        run = self.recovery['run']
        context = json.loads((self.recovery_dir / ('%08x-context.json' % run)).read_text())
        if context['run'] != run or not context.get('synthetic'):
            raise gcmd.error('Recovery context mismatch')
        if self.recovery['xyze_um'] != self.sample(self.recovery['sequence']):
            raise gcmd.error('Recovery sample mismatch')
        if context['filename']:
            base = Path(self.printer.lookup_object('virtual_sdcard').sdcard_dirname)
            if hashlib.sha256((base / context['filename']).read_bytes()).hexdigest() != context['sha256']:
                raise gcmd.error('Recovery file changed')
        result = dict(record=self.recovery, context=context,
                      sample_age_ms=((self.recovery['trip_clock']-
                          self.recovery['sample_clock']) & 0xffffffff)
                          / self.mcu.seconds_to_clock(.001))
        self._durable(self.recovery_dir / ('%08x-handoff.json' % run), result)
        gcmd.respond_info('Recovery durably copied; STM32 record still pending')

    def cmd_RECOVERY_CONSUME(self, gcmd):
        self.recovery = self._read_recovery()
        if not self.recovery['pending']:
            raise gcmd.error('No pending recovery record')
        path = self.recovery_dir / ('%08x-handoff.json' % self.recovery['run'])
        if not path.is_file():
            raise gcmd.error('No durable recovery handoff; record retained')
        handoff = json.loads(path.read_text())
        for key in ('run', 'sequence', 'sample_clock', 'trip_clock', 'xyze_um', 'crc'):
            if handoff['record'][key] != self.recovery[key]:
                raise gcmd.error('Recovery handoff mismatch')
        self.recovery_consume.send([self.recovery['run']])
        self.recovery = self._read_recovery()
        if self.recovery['pending']:
            raise gcmd.error('Recovery consume did not complete')
        gcmd.respond_info('STM32 record consumed; MCU restart required before next test')

def load_config(config):
    return PowerMonitor(config)
