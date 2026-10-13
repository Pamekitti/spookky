import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import check


class CheckReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", self.root], check=True)
        (self.root / ".gitignore").write_text(".cache/\n")
        (self.root / "README.md").write_text("fixture")
        (self.root / ".cache").mkdir()
        self.command = [sys.executable, "-c", "from pathlib import Path; p=Path('.cache/count'); p.write_text(str(int(p.read_text())+1) if p.exists() else '1')"]

    def run_check(self, command=None, *, force=False):
        with patch.object(check, "ROOT", self.root), patch.object(check, "changed_paths", return_value=(["README.md"], False)), \
                patch.object(check, "commands", return_value=[command or self.command]), \
                patch.object(sys, "argv", ["check.py", *(["--force"] if force else [])]), contextlib.redirect_stdout(io.StringIO()):
            check.main()

    def test_reuse_requires_matching_source_and_command(self):
        self.run_check()
        self.run_check()
        self.assertEqual((self.root / ".cache/count").read_text(), "1")
        (self.root / "README.md").write_text("changed fixture")
        self.run_check()
        self.assertEqual((self.root / ".cache/count").read_text(), "2")

    def test_force_and_corrupt_receipts_rerun_checks(self):
        self.run_check()
        self.run_check(force=True)
        (self.root / ".cache/checks/last.json").write_text("interrupted write")
        self.run_check()
        self.assertEqual((self.root / ".cache/count").read_text(), "3")

    def test_failure_and_source_edits_during_checks_cannot_leave_a_pass_receipt(self):
        self.run_check()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check([sys.executable, "-c", "raise SystemExit(1)"], force=True)
        self.assertFalse((self.root / ".cache/checks/last.json").exists())
        with self.assertRaisesRegex(SystemExit, "Source changed"):
            self.run_check([sys.executable, "-c", "from pathlib import Path; Path('README.md').write_text('concurrent change')"])
        self.assertFalse((self.root / ".cache/checks/last.json").exists())


if __name__ == "__main__":
    unittest.main()
