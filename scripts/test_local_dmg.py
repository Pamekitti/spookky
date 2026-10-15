import plistlib
from pathlib import Path
import json
import select
import subprocess
import sys
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from prepare_local_dmg import local_info
from verify_bundle import library_paths, verify


class LocalInstallerTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleExecutable": "Spookky", "CFBundleIdentifier": "dev.spookky.m0",
                     "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "100",
                     "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "public-key",
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                     "SUSignedFeedFailureExpirationInterval": 0}

    def test_local_packaging_removes_development_identity_and_paths(self):
        info = local_info({"CFBundleExecutable": "Spookky", "CFBundleIdentifier": "dev.spookky.development." + "a" * 16,
                           "CFBundleShortVersionString": "0.1.3", "CFBundleDisplayName": "Spookky Dev (fixture)",
                           "SpookkyDevelopmentCheckout": "/private/checkouts/fixture"}, "b" * 40)
        self.assertEqual(info["CFBundleIdentifier"], "dev.spookky.app")
        self.assertEqual(info["CFBundleDisplayName"], "Spookky")
        self.assertNotIn("SpookkyDevelopmentCheckout", info)

    def test_local_install_keeps_future_identity_without_fetching_public_updates(self):
        local = local_info(self.info, "a" * 40)
        self.assertEqual(local["CFBundleIdentifier"], "dev.spookky.app")
        self.assertNotIn("SUFeedURL", local)
        self.assertNotIn("SUPublicEDKey", local)
        self.assertIs(local["SUEnableAutomaticChecks"], False)
        self.assertIs(local["SUAutomaticallyUpdate"], False)
        self.assertIn("SUFeedURL", self.info)

    def test_local_artifact_cannot_pass_public_release_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Spookky.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(local_info(self.info, "a" * 40)))
            with self.assertRaisesRegex(ValueError, "Local installers cannot pass public"):
                verify(app)

    def test_unrelated_app_and_unsafe_artifact_version_are_rejected(self):
        for changes in [{"CFBundleExecutable": "AnotherApp"}, {"CFBundleShortVersionString": "../../outside"}]:
            with self.assertRaises(ValueError):
                local_info(dict(self.info, **changes), "a" * 40)
        with self.assertRaises(ValueError): local_info(self.info, "not-a-source-commit")

    def test_universal_binary_headers_are_not_dependencies(self):
        output = "/Users/build/work/Autoupdate (architecture arm64):\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)\n/Users/build/work/Autoupdate (architecture x86_64):\n\t/opt/unbundled/lib.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
        self.assertEqual(library_paths(output), ["/usr/lib/libSystem.B.dylib", "/opt/unbundled/lib.dylib"])

    def test_download_server_only_serves_local_installer_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = "Spookky-0.1.0-local-arm64.dmg"
            (root / "local-build.json").write_text(json.dumps({"kind": "local", "asset": asset}))
            (root / "index.html").write_text("Local download")
            (root / asset).write_bytes(b"installer")
            (root / ".not-found").write_text("private")
            (root / "private.txt").write_text("private")
            (root / "icon.png").symlink_to(root / "private.txt")
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("serve_local_download.py")),
                                        "--directory", str(root), "--port", "0"],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Download server did not start")
                address = process.stdout.readline().strip()
                self.assertTrue(address.startswith("http://127.0.0.1:"))
                with urlopen(address, timeout=2) as response:
                    self.assertEqual(response.read(), b"Local download")
                with urlopen(address + asset, timeout=2) as response:
                    self.assertEqual(response.read(), b"installer")
                    self.assertIn("attachment", response.headers["Content-Disposition"])
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
                for path in ("private.txt", ".not-found", "%2e%2e/private.txt", "icon.png", "Spookky.app/"):
                    with self.subTest(path=path), self.assertRaises(HTTPError) as rejected:
                        urlopen(address + path, timeout=2)
                    self.assertEqual(rejected.exception.code, 404)
                    rejected.exception.close()
            finally:
                process.terminate()
                process.wait(timeout=5)
                process.stdout.close()


if __name__ == "__main__": unittest.main()
