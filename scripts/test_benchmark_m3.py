import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import benchmark_m3


class PreviewTimingCommandTests(unittest.TestCase):
    def test_timing_cli_keeps_files_and_the_selected_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'Frozen app'
            binary.write_bytes(b'fixture executable')
            output = Path(folder) / 'timing.json'
            arguments = ['benchmark_m3.py', '--mode', 'timing', '--binary', str(binary), '--output', str(output)]
            measurements = {'warm_selection': {'failure_count': 0}}
            with patch('sys.argv', arguments), patch('benchmark_m3.benchmark_m1.timing', return_value=measurements) as timing:
                with contextlib.redirect_stdout(io.StringIO()):
                    benchmark_m3.main()
            timing.assert_called_once_with(resize=False, binary=binary,
                                          extra_arguments=['--workspace-benchmark-files'], prepare=benchmark_m3.prepare)
            report = json.loads(output.read_text())
            self.assertEqual(report['timing'], measurements)
            self.assertFalse(report['binary_changed_during_run'])
            self.assertEqual(report['failure_count'], 0)


if __name__ == '__main__':
    unittest.main()
