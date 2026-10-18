#!/usr/bin/env python3
"""Build and open a development app belonging to this checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def identity(checkout):
    return hashlib.sha256(str(Path(checkout).resolve()).encode()).hexdigest()[:16]


def configuration(checkout, build):
    checkout = Path(checkout).resolve()
    key = identity(checkout)
    return {
        "checkout": str(checkout),
        "id": key,
        "bundleID": "dev.spookky.development." + key,
        "name": "Spookky Dev (" + checkout.name + ")",
        "app": str(checkout / "DerivedData/Build/Products" / build / "Spookky.app"),
        "data": str(Path.home() / "Library/Application Support/Spookky/Development" / key),
        "runtime": "/tmp/spookky-dev-" + str(os.getuid()) + "-" + key,
    }


def build_app(config, build):
    developer = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    if not Path(developer).is_dir():
        raise ValueError("Full Xcode is required. See docs/development.md.")
    for relative, command in [(".cache/runtime/bin/tmux", "python3 scripts/build_runtime.py"),
                              (".cache/dependencies/ghostty/macos/GhosttyKit.xcframework", "python3 scripts/build_ghostty.py")]:
        if not (ROOT / relative).exists():
            raise ValueError("Build the pinned dependency first: " + command)
    executables = {str(ROOT / "DerivedData/Build/Products" / mode / "Spookky.app/Contents/MacOS/Spookky")
                   for mode in ["Debug", "Release"]}
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    if executables.intersection(line.strip() for line in processes):
        raise ValueError("Quit this worktree's development app before rebuilding. Choose Keep sessions running to retain its terminals.")
    environment = dict(os.environ, DEVELOPER_DIR=developer)
    subprocess.run(["xcodebuild", "-jobs", "2", "-project", "Spookky.xcodeproj", "-scheme", "Spookky",
                    "-configuration", build, "-derivedDataPath", "DerivedData", "ARCHS=arm64",
                    "PRODUCT_BUNDLE_IDENTIFIER=" + config["bundleID"],
                    "SPOOKKY_DISPLAY_NAME=" + config["name"], "OTHER_SWIFT_FLAGS=$(inherited) -j2", "build"], cwd=ROOT, env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["info", "build", "run"])
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    args = parser.parse_args()
    config = configuration(ROOT, args.configuration)
    if args.action == "info":
        print(json.dumps(config, indent=2))
        return
    build_app(config, args.configuration)
    print(json.dumps(config, indent=2), flush=True)
    if args.action == "run":
        # Fixture overrides must not redirect a normal development run into another instance.
        subprocess.run(["/usr/bin/open", "--env", "SPOOKKY_M1_ROOT=" + config["runtime"],
                        "--env", "SPOOKKY_M1_DATA=" + config["data"],
                        "--env", "SPOOKKY_M0_ROOT=/tmp/spookky-m0-" + str(os.getuid()) + "-" + config["id"],
                        config["app"]], check=True)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error))
