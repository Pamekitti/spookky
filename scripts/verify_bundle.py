#!/usr/bin/env python3
"""Check a packaged app's runtime, resources, and external library paths."""

import plistlib
from pathlib import Path
import subprocess
import sys


def library_paths(output):
    return [
        line.strip().split(" (compatibility version", 1)[0]
        for line in output.splitlines()
        if " (compatibility version" in line
    ]


def verify(app, *, local=False):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if (
        "harness" in info.get("CFBundleIdentifier", "").lower()
        or any(contents.rglob("*.xctest"))
        or any(path.name == "SpookkyHarness" for path in contents.rglob("*"))
    ):
        raise ValueError("Harness and test artifacts cannot be packaged")
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]:
        if info.get(key) is not True:
            raise ValueError("Missing signed-update requirement: " + key)
    if info.get("SUSignedFeedFailureExpirationInterval") != 0:
        raise ValueError("Unsigned-feed fallback must stay disabled")
    if local:
        if (
            info.get("SpookkyBuildKind") != "local"
            or info["CFBundleIdentifier"] != "dev.spookky.app"
        ):
            raise ValueError("Local installer identity is invalid")
        if (
            info.get("SUFeedURL")
            or info.get("SUPublicEDKey")
            or info.get("SUEnableAutomaticChecks") is not False
            or info.get("SUAutomaticallyUpdate") is not False
        ):
            raise ValueError("Local installers must disable public updates")
    else:
        if info.get("SpookkyBuildKind") == "local":
            raise ValueError("Local installers cannot pass public release verification")
        if not info.get("SUFeedURL", "").startswith("https://") or not info.get(
            "SUPublicEDKey"
        ):
            raise ValueError("Missing production feed or public update key")
        if "SUEnableAutomaticChecks" in info:
            raise ValueError("Leave automatic checks unset until user consent")
    for name in ["Spookky", "spookky-launch", "spookky-runtime-check", "tmux"]:
        binary = contents / "MacOS" / name
        if not binary.is_file():
            raise ValueError("Missing executable: " + name)
    for name in ["ghostty", "terminfo", "licenses"]:
        if not (contents / "Resources" / name).is_dir():
            raise ValueError("Missing resource: " + name)
    if not (contents / "Frameworks/Sparkle.framework").is_dir():
        raise ValueError("Missing updater framework")
    for path in contents.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        if "Mach-O" not in subprocess.check_output(["file", "-b", path], text=True):
            continue
        if (
            info["CFBundleIdentifier"] == "dev.spookky.app"
            and str(Path.home()).encode() in path.read_bytes()
        ):
            raise ValueError("Private build path remains in " + path.name)
        for library in library_paths(
            subprocess.check_output(["otool", "-L", path], text=True)
        ):
            if (
                library.startswith("/opt/")
                or library.startswith("/Users/")
                or library.startswith("/usr/local/")
            ):
                raise ValueError("External library in " + path.name + ": " + library)
    print("Bundle runtime/resource audit passed:", info["CFBundleIdentifier"])


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument(
        "--local",
        action="store_true",
        help="Verify a private local installer with updates disabled",
    )
    args = parser.parse_args()
    verify(args.app, local=args.local)
