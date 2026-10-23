import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest


class TerminalInputFixtureTests(unittest.TestCase):
    def test_exit_keeps_bytes_before_shortcut(self):
        for shortcut in [b"\x11", b"\x1b[113;5u", b"\x1b[27;5;113~"]:
            with self.subTest(shortcut=shortcut):
                self.verify_exit(shortcut)

    def verify_exit(self, shortcut):
        master, slave = pty.openpty()
        process = None
        try:
            with tempfile.TemporaryDirectory(prefix="spookky-byte-check-") as root:
                output = Path(root) / "bytes.json"
                script = Path(__file__).resolve().parents[2] / "scripts/terminal_input_fixture.py"
                process = subprocess.Popen([sys.executable, str(script), "--output", str(output)], stdin=slave, stdout=slave, stderr=slave)
                screen = b""
                deadline = time.monotonic() + 5
                while b"INPUT CHECK READY" not in screen:
                    self.assertLess(time.monotonic(), deadline, "Fixture did not start")
                    if select.select([master], [], [], 0.1)[0]:
                        screen += os.read(master, 4096)
                expected = "café ไทย".encode()
                os.write(master, expected + shortcut + b"ignored")
                deadline = time.monotonic() + 5
                while process.poll() is None:
                    self.assertLess(time.monotonic(), deadline, "Fixture did not exit")
                    if select.select([master], [], [], 0.1)[0]:
                        os.read(master, 4096)
                self.assertEqual(process.returncode, 0)
                records = json.loads(output.read_text())
                self.assertEqual(bytes.fromhex(records[-1]["hex"]), expected)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
