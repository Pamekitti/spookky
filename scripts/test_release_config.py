import copy
import json
from pathlib import Path
import unittest
from prepare_release import validate_config, validate_source_commit


class ReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((Path(__file__).resolve().parents[1] / "release.json").read_text())
        self.config.update(version="0.1.0", channel="preview", build=100)

    def test_tag_channel_and_version_must_agree(self):
        for tag in ["v0.1.0", "v9.1.0-preview.1", "v0.1.0-preview.0", "v0.1.0-preview.1;ignored"]:
            with self.assertRaises(ValueError): validate_config(self.config, tag)

    def test_build_numbers_cannot_be_reused(self):
        with self.assertRaises(ValueError): validate_config(self.config, "v0.1.0-preview.1", {"build":100})

    def test_public_key_is_required(self):
        config = copy.deepcopy(self.config); config["publicEDKey"] = ""
        with self.assertRaises(ValueError): validate_config(config, "v0.1.0-preview.1")

    def test_development_identity_cannot_ship(self):
        config = copy.deepcopy(self.config); config["bundleID"] = "dev.spookky.m0"
        with self.assertRaises(ValueError): validate_config(config, "v0.1.0-preview.1")

    def test_unreviewed_or_missing_main_cannot_ship(self):
        head = "a" * 40
        validate_source_commit(head, head)
        for main in ["b" * 40, "", "a"]:
            with self.assertRaises(ValueError): validate_source_commit(head, main)


if __name__ == "__main__": unittest.main()
