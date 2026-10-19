import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from check_agent_hooks import run


class AgentHookCheckerTests(unittest.TestCase):
    def test_failed_helper_launch_closes_the_listener_thread(self):
        before = set(threading.enumerate())
        with patch("check_agent_hooks.subprocess.Popen", side_effect=FileNotFoundError("missing helper")):
            with self.assertRaises(FileNotFoundError):
                run("claude", helper=Path("/missing fixture/helper"))
        self.assertEqual(set(threading.enumerate()) - before, set())

    def test_missing_provider_does_not_start_a_listener_thread(self):
        before = set(threading.enumerate())
        with patch("check_agent_hooks.shutil.which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "claude is not installed"):
                run("claude", real=True)
        self.assertEqual(set(threading.enumerate()) - before, set())


if __name__ == "__main__":
    unittest.main()
