"""Exact-ID notification receipts never retain conversation text or replace user notifications."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from runtime_paths import launch_helper_path

HELPER = launch_helper_path()


@unittest.skipUnless(HELPER.is_file(), 'Build spookky-launch first')
class AgentIdentityTests(unittest.TestCase):
    def test_notification_receipt_is_bounded_and_preserves_native_notification(self):
        with tempfile.TemporaryDirectory(prefix='spookky-identity-') as directory:
            root = Path(directory)
            binding, secret = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
            context = root / ('agent-terminal-' + binding + '.json')
            context.write_text(json.dumps(dict(bindingID=binding, secret=secret, root=directory, helper=str(HELPER))))
            context.chmod(0o600)
            forwarded = root / 'forwarded.json'
            command = [sys.executable, '-c', 'import pathlib,sys;pathlib.Path(sys.argv[1]).write_text(sys.argv[2])', str(forwarded)]
            encoded = base64.b64encode(json.dumps(command).encode()).decode()
            ids = [str(uuid.uuid4()) for _ in range(10)]
            for session in ids:
                payload = json.dumps({'type': 'agent-turn-complete', 'thread-id': session,
                                      'last-assistant-message': 'Do not retain this text $(never-execute)', 'input-messages': ['private draft']})
                result = subprocess.run([str(HELPER), '--agent-identity', str(context), encoded, payload],
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(forwarded.read_text(), payload)
            receipt = json.loads((root / ('agent-identity-' + binding + '.json')).read_text())
            self.assertEqual(receipt['candidates'], ids[-8:])
            self.assertEqual(set(receipt), {'bindingID', 'secret', 'candidates'})
            self.assertEqual(receipt['secret'], secret)
            self.assertTrue((root / 'runtime-event').is_file())
            self.assertNotIn('private draft', json.dumps(receipt))

    def test_untrusted_context_cannot_create_a_receipt(self):
        with tempfile.TemporaryDirectory(prefix='spookky-identity-') as directory:
            payload = json.dumps({'type': 'agent-turn-complete', 'thread-id': str(uuid.uuid4())})
            subprocess.run([str(HELPER), '--agent-identity', directory + '/missing.json', 'W10=', payload], check=True, timeout=3)
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
