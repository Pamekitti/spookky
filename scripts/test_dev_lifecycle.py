from pathlib import Path
import tempfile
import unittest

from dev import configuration


class DevelopmentLifecycleTests(unittest.TestCase):
    def test_checkouts_are_separate_and_symlink_aliases_are_equal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first checkout"
            first.mkdir()
            alias = root / "alias"
            alias.symlink_to(first, target_is_directory=True)
            one = configuration(first, "Debug")
            two = configuration(root / "second checkout", "Debug")
            self.assertEqual(one, configuration(alias, "Debug"))
            for key in ("bundleID", "app", "data", "runtime"):
                self.assertNotEqual(one[key], two[key])
            self.assertEqual(one["data"], configuration(first, "Release")["data"])


if __name__ == "__main__":
    unittest.main()
