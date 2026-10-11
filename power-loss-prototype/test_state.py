"""Integrity checks for the experimental state record (no GPIO required)."""
import importlib.machinery
from pathlib import Path
import unittest

save = importlib.machinery.SourceFileLoader(
    'power_loss_save', str(Path(__file__).with_name('power-loss-save'))).load_module()


class StateRecord(unittest.TestCase):
    def setUp(self):
        self.record = {'run': 'new-run', 'state': {'file_position': 1234, 'position': [1, 2, 3, 4]}}
        self.block = save.encode(self.record)

    def test_round_trip(self):
        self.assertEqual(len(self.block), 4096)
        self.assertEqual(save.decode(self.block), self.record)

    def test_torn_payload_rejected(self):
        damaged = bytearray(self.block)
        damaged[save.HEADER.size + 5] ^= 1
        with self.assertRaisesRegex(ValueError, 'CRC mismatch'):
            save.decode(damaged)

    def test_unwritten_and_truncated_rejected(self):
        for block in (bytes(4096), self.block[:-1]):
            with self.subTest(length=len(block)), self.assertRaises(ValueError):
                save.decode(block)

    def test_out_of_bounds_header_rejected(self):
        for size in (0, 4097):
            block = save.HEADER.pack(save.MAGIC, size, 0).ljust(4096, b'\0')
            with self.subTest(size=size), self.assertRaises(ValueError):
                save.decode(block)

    def test_oversized_snapshot_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            save.encode({'payload': 'x'*4096})


if __name__ == '__main__':
    unittest.main()
