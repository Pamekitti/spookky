import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from fixture_results import validate_checks, report
from gui_lock import gui_lock

class FixtureResultsTests(unittest.TestCase):
    def test_behavior_required_even_when_binary_matches(self):
        for value in [{}, {'verified_binary_unchanged': True}]:
            with self.assertRaises(ValueError): validate_checks(value, {'native_input'})
    def test_partial_malformed_and_false_reports_fail(self):
        for value in [None, [], {'a': 1}, {'a': 'true'}, {'a': False}, {'b': True}]:
            with self.assertRaises(ValueError): validate_checks(value, {'a'})
        with self.assertRaises(ValueError): validate_checks({'a': True}, set())
    def test_complete_report_has_separate_identity_and_counts(self):
        result=report('composer', {'a': True}, {'a'}, binary_sha256='f'*64)
        self.assertEqual(result['counts']['passed'], 1)
        self.assertEqual(result['checks'], {'a': True})
    def test_cross_process_lock_contention_and_release(self):
        with tempfile.TemporaryDirectory() as root:
            lock=Path(root)/'lock'
            command=[sys.executable,'-c', 'from gui_lock import gui_lock\nimport sys\nwith gui_lock(path=sys.argv[1],timeout=0): pass',str(lock)]
            import os
            env=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parents[2]/'scripts'))
            with gui_lock(path=lock):
                self.assertNotEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)
            self.assertEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)

class RunnerDiscoveryTests(unittest.TestCase):
    def test_zero_discovery_fails(self):
        import importlib.util
        path=Path(__file__).resolve().parents[2]/'scripts/test.py'
        spec=importlib.util.spec_from_file_location('spookky_test_runner',path)
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        with self.assertRaises(RuntimeError):runner.require_discovered(0,'selected')
        runner.require_discovered(1,'selected')

class TestInventoryTests(unittest.TestCase):
    def test_existing_swift_scenarios_remain_discoverable(self):
        from collections import Counter
        import re
        root=Path(__file__).resolve().parents[2]
        expected=json.loads((root/'Tests/Inventory/swift-cases.json').read_text())
        actual=[]
        for group in ['SpookkyUnitTests','SpookkyIntegrationTests','SpookkyProviderTests']:
            for source in (root/'Tests'/group).rglob('*.swift'):
                actual+=re.findall(r'func (test\w+)\(',source.read_text())
        self.assertFalse(Counter(expected)-Counter(actual), 'An existing scenario disappeared')
