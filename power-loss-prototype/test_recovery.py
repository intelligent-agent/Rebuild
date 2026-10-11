"""Checks real record decoding and handoff gates without GPIO/hardware."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
spec=importlib.util.spec_from_file_location('monitor',Path(__file__).parent/'klippy/extras/power_monitor.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class Query:
    def __init__(self, raw):self.raw=raw
    def send(self,args):return dict(pending=1,saved=0,applied=0,dropped=0,data=self.raw)
class Printer:
    command_error=ValueError
class Recovery(unittest.TestCase):
    def setUp(self):
        self.host=module.PowerMonitor.__new__(module.PowerMonitor)
        self.host.printer=Printer()
        body=struct.pack('<5I4i',0x31524c50,123,17,0xfffff000,0x100,module.PowerMonitor.sample(17)[0],*module.PowerMonitor.sample(17)[1:])
        self.raw=body+struct.pack('<IHH',zlib.crc32(body),0xa55a,0xffff)
        self.host.recovery_query=Query(self.raw)
    def test_readback_exact(self):
        record=self.host._read_recovery()
        self.assertEqual(record['run'],123)
        self.assertEqual(record['xyze_um'],module.PowerMonitor.sample(17))
        self.assertEqual(len(self.raw),44)
    def test_torn_header_and_payload(self):
        for index in (0,20,36,40,42):
            raw=bytearray(self.raw);raw[index]^=1
            self.host.recovery_query=Query(raw)
            with self.subTest(index=index),self.assertRaises(ValueError):self.host._read_recovery()
    def test_truncated_record_rejected(self):
        self.host.recovery_query=Query(self.raw[:-1])
        with self.assertRaisesRegex(ValueError,'record length'):
            self.host._read_recovery()

    def test_pending_false_does_not_parse_erased_flash(self):
        self.host.recovery_query.send=lambda args:dict(pending=0,saved=0,applied=0,dropped=0,data=b'\xff'*44)
        self.assertFalse(self.host._read_recovery()['pending'])
    def test_durable_handoff(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'record.json'
            module.PowerMonitor._durable(path,dict(run=123))
            self.assertEqual(json.loads(path.read_text()),dict(run=123))
            self.assertFalse(path.with_suffix('.tmp').exists())
    def test_consume_refuses_without_handoff(self):
        class Gcmd:
            error=ValueError
        class Sender:
            def send(self,args):raise AssertionError('Must not touch flash')
        with tempfile.TemporaryDirectory() as folder:
            self.host.recovery_dir=Path(folder)
            self.host.recovery_consume=Sender()
            with self.assertRaisesRegex(ValueError,'No durable recovery handoff'):
                self.host.cmd_RECOVERY_CONSUME(Gcmd())

    def test_synthetic_wire_range(self):
        for sequence in (0,17,999,1000,50000,3000000):
            raw=struct.pack('<4h',*module.PowerMonitor.sample(sequence))
            self.assertEqual(len(raw),8)
if __name__=='__main__':unittest.main()
