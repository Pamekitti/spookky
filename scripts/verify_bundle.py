#!/usr/bin/env python3
"""Check a packaged app's runtime, resources, and external library paths."""
import plistlib
from pathlib import Path
import subprocess
import sys


def verify(app):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]:
        if info.get(key) is not True: raise ValueError("Missing signed-update requirement: " + key)
    if info.get("SUSignedFeedFailureExpirationInterval") != 0: raise ValueError("Unsigned-feed fallback must stay disabled")
    if not info.get("SUFeedURL", "").startswith("https://") or not info.get("SUPublicEDKey"):
        raise ValueError("Missing production feed or public update key")
    if "SUEnableAutomaticChecks" in info: raise ValueError("Leave automatic checks unset until user consent")
    for name in ["Spookky", "spookky-launch", "spookky-runtime-check", "tmux"]:
        binary = contents / "MacOS" / name
        if not binary.is_file(): raise ValueError("Missing executable: " + name)
    for name in ["ghostty", "terminfo", "licenses"]:
        if not (contents / "Resources" / name).is_dir(): raise ValueError("Missing resource: " + name)
    if not (contents / "Frameworks/Sparkle.framework").is_dir(): raise ValueError("Missing updater framework")
    for path in contents.rglob("*"):
        if not path.is_file() or path.is_symlink(): continue
        if "Mach-O" not in subprocess.check_output(["file", "-b", path], text=True): continue
        if info["CFBundleIdentifier"] == "dev.spookky.app" and str(Path.home()).encode() in path.read_bytes():
            raise ValueError("Private build path remains in " + path.name)
        for line in subprocess.check_output(["otool", "-L", path], text=True).splitlines()[1:]:
            library = line.strip().split(" (", 1)[0]
            if library.startswith("/opt/") or library.startswith("/Users/") or library.startswith("/usr/local/"):
                raise ValueError("External library in " + path.name + ": " + library)
    print("Bundle runtime/resource audit passed:", info["CFBundleIdentifier"])


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
