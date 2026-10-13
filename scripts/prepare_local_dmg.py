#!/usr/bin/env python3
"""Package a tested app for private local installation without Apple membership."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from create_dmg import create
from verify_bundle import verify

ROOT = Path(__file__).resolve().parents[1]


def run(arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def local_info(info, source_commit):
    if info.get("CFBundleExecutable") != "Spookky" or info.get("CFBundleIdentifier") not in ("dev.spookky.m0", "dev.spookky.app"):
        raise ValueError("Use a tested Spookky app bundle")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit): raise ValueError("Use the full tested source commit")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(info.get("CFBundleShortVersionString", ""))):
        raise ValueError("Use a numeric app version")
    result = dict(info)
    result.update(CFBundleIdentifier="dev.spookky.app", SpookkyBuildKind="local", SpookkySourceCommit=source_commit,
                  SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
    for key in ("SUFeedURL", "SUPublicEDKey"): result.pop(key, None)
    return result


def sign_local(app):
    binaries = [path for path in app.rglob("*") if path.is_file() and not path.is_symlink() and
                "Mach-O" in subprocess.check_output(["file", "-b", path], text=True)]
    for path in sorted(binaries, key=lambda value: len(value.parts), reverse=True):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements", path])
    bundles = [path for path in app.rglob("*") if path.is_dir() and not path.is_symlink() and path.suffix in (".app", ".xpc", ".framework")]
    for path in sorted(bundles, key=lambda value: len(value.parts), reverse=True) + [app]:
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements", path])
    run(["codesign", "--verify", "--deep", "--strict", app])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True, help="Existing tested app; it is copied, never modified")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", type=Path, required=True, help="Fresh private output directory")
    args = parser.parse_args()
    source = args.app.resolve()
    info = local_info(plistlib.loads((source / "Contents/Info.plist").read_bytes()), args.source_commit)
    architectures = subprocess.check_output(["lipo", "-archs", source / "Contents/MacOS/Spookky"], text=True).split()
    if "arm64" not in architectures: raise SystemExit("Local installers currently require an Apple Silicon app")
    output = args.output.resolve()
    if output == source or source in output.parents: raise SystemExit("Output must stay outside the source app")
    if output.exists(): raise SystemExit("Output exists; choose a fresh directory")
    output.mkdir(parents=True, mode=0o700)
    app = output / "Spookky.app"
    run(["ditto", source, app])
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    for binary in (app / "Contents/MacOS").iterdir():
        if binary.is_file(): run(["strip", "-S", binary])
    sign_local(app)
    verify(app, local=True)
    name = "Spookky-" + info["CFBundleShortVersionString"] + "-local-arm64.dmg"
    dmg = output / name
    create(app, ROOT / "website/assets/dmg-background.tiff", dmg)
    run(["hdiutil", "verify", dmg])
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(digest + "  " + name + "\n")
    manifest = {"kind": "local", "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                "sourceCommit": args.source_commit, "architecture": "arm64", "appleNotarized": False,
                "automaticUpdates": False, "asset": name, "bytes": dmg.stat().st_size, "sha256": digest}
    (output / "local-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(ROOT / "App/Assets.xcassets/AppIcon.appiconset/icon-256@1x.png", output / "icon.png")
    page = (ROOT / "scripts/local-download.html").read_text().replace("{{ASSET}}", name).replace("{{VERSION}}", info["CFBundleShortVersionString"])
    (output / "index.html").write_text(page)
    print("Prepared private local installer:", dmg)
    print("Apple notarization and automatic updates are disabled. Public release metadata was not changed.")


if __name__ == "__main__": main()
