import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'rebuild-recore/usr/lib/rebuild/diag'
sys.path.insert(0, str(ROOT))
import recore_diag as diag
from stress_log import format_record


class DiagTests(unittest.TestCase):
    def test_report_default_has_no_load(self):
        a = diag.options([])
        self.assertFalse(a.stress)
        self.assertFalse(a.cpu or a.gpu or a.memory)
        self.assertFalse(a.verbose)

    def test_verbose_is_opt_in(self):
        self.assertTrue(diag.options(['--verbose']).verbose)

    def test_simple_flags_translate_to_worker(self):
        a = diag.options(['--stress', '--cpu', '--gpu', '--memory', '--minutes', '20', '--interval', '7'])
        c = diag.configuration(a)
        self.assertEqual(c['duration_seconds'], 1200)
        self.assertEqual(c['sample_seconds'], 7)
        self.assertTrue(c['install_tools'])
        self.assertEqual(c['memory_loops'], 1)

    def test_invalid_flags_refused(self):
        for flags in (['--cpu'], ['--stress'], ['--minutes', 'nan'], ['--interval', '0'], ['--last', '--stress', '--memory']):
            with self.subTest(flags=flags), self.assertRaises(SystemExit):
                diag.options(flags)

    def test_readable_telemetry_preserves_missing_values(self):
        line = format_record('TELEMETRY', {'elapsed_seconds':60, 'remaining_seconds':120,
                    'temperatures_c':{'cpu-thermal':72.4}, 'cpu_khz':'1008000', 'gpu_hz':None,
                    'memory_failures':3, 'memory_loops_completed':2, 'loads':{'memory':'running'}})
        for part in ('01:00', '72.4 C', 'CPU 1008 MHz', 'GPU unavailable', 'errors: 3', 'memory running'):
            self.assertIn(part, line)

    def test_worker_snapshot_parses(self):
        compile((ROOT / 'stress-workload.py').read_text(), 'stress-workload.py', 'exec')

    def test_compact_sample(self):
        line = diag.compact_sample({'elapsed_seconds':382, 'remaining_seconds':818,
            'temperatures_c':{'gpu0':80}, 'cpu_khz':'1008000', 'gpu_hz':180000000,
            'gpu_fps':42, 'memory_loops_completed':3, 'memory_failures':0,
            'loads':{'gpu':'running', 'memory':'running'}})
        self.assertEqual(line, 'time:6:22/13:38 gpu0:80.0C cpu:1008MHz gpu:180MHz fps:42 mem:3p/0e')
        self.assertNotIn('\n', line)

    def test_compact_missing_readings(self):
        self.assertIn('temp:? cpu:?MHz gpu:?MHz', diag.compact_sample({}))


if __name__ == '__main__':
    unittest.main()
