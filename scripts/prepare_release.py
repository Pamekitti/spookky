#!/usr/bin/env python3
"""Archive, sign, notarize, and prepare a draft release without publishing it."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def validate_config(config, tag, previous=None):
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-preview\.[1-9]\d*)?", tag):
        raise ValueError("Use a semantic release tag, such as v0.1.0-preview.1.")
    if tag[1:].split("-", 1)[0] != config["version"]:
        raise ValueError("Tag and release.json version differ.")
    if config["channel"] not in ("preview", "stable") or ("-preview." in tag) != (config["channel"] == "preview"):
        raise ValueError("Tag and release channel differ.")
    if config["bundleID"] != "dev.spookky.app" or config["architecture"] != "arm64":
        raise ValueError("Unexpected release identity or architecture.")
    if not isinstance(config["build"], int) or config["build"] < 100:
        raise ValueError("Release builds must be integers of at least 100.")
    if len(base64.b64decode(config["publicEDKey"], validate=True)) != 32:
        raise ValueError("Configure the actual Sparkle public key before building a release.")
    if previous and config["build"] <= previous["build"]:
        raise ValueError("Release build numbers must increase.")


def signing_arguments(tool):
    key = os.environ.get("SPOOKKY_ED_KEY_FILE")
    return [tool, "--ed-key-file", key] if key else [tool, "--account", "dev.spookky.app"]


def validate_source_commit(head, main):
    if not re.fullmatch(r"[0-9a-f]{40}", main) or head != main:
        raise ValueError("Prepare releases from the current reviewed main commit.")


def sign_nested(app, identity):
    candidates = []
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        kind = subprocess.check_output(["file", "-b", path], text=True)
        if "Mach-O" in kind:
            candidates.append(path)
    for path in sorted(candidates, key=lambda p: len(p.parts), reverse=True):
        run(["codesign", "--force", "--options", "runtime", "--timestamp", "--preserve-metadata=entitlements", "--sign", identity, path])
    bundles = [p for p in app.rglob("*") if p.suffix in (".app", ".xpc", ".framework") and p.is_dir() and not p.is_symlink()]
    for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        run(["codesign", "--force", "--options", "runtime", "--timestamp", "--preserve-metadata=entitlements", "--sign", identity, path])
    run(["codesign", "--verify", "--deep", "--strict", app])


def submit_notarization(path, profile):
    result = run(["xcrun", "notarytool", "submit", path, "--keychain-profile", profile, "--wait", "--output-format", "json"], capture_output=True, text=True)
    if json.loads(result.stdout).get("status") != "Accepted":
        raise SystemExit("Apple did not accept the notarization submission. Inspect its private log before proceeding.")


def notarize(path, profile):
    submit_notarization(path, profile)
    run(["xcrun", "stapler", "staple", path])
    run(["xcrun", "stapler", "validate", path])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--notary-profile", required=True)
    parser.add_argument("--sparkle-tools", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    args = parser.parse_args()
    config = json.loads((ROOT / "release.json").read_text())
    previous = json.loads((ROOT / "website/release-manifest.json").read_text()).get("release")
    validate_config(config, args.tag, previous)
    key_file = os.environ.get("SPOOKKY_ED_KEY_FILE")
    if key_file:
        run(["xcrun", "swift", ROOT / "scripts/verify_update_key.swift", key_file, config["publicEDKey"]])
    else:
        public_key = subprocess.check_output([str(args.sparkle_tools / "generate_keys"), "--account", "dev.spookky.app", "-p"], text=True).strip()
        if public_key != config["publicEDKey"]: raise SystemExit("The Keychain update key differs from release.json.")
    if not args.identity.startswith("Developer ID Application:"):
        raise SystemExit("A Developer ID Application identity is required.")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
        raise SystemExit("Release from a clean committed checkout.")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    main_ref = subprocess.check_output(["git", "ls-remote", "https://github.com/Pamekitti/spookky.git", "refs/heads/main"], cwd=ROOT, text=True).split()
    validate_source_commit(head, main_ref[0] if main_ref else "")
    output = args.output.resolve()
    if output.exists():
        raise SystemExit("Use a new output folder for each release; existing artifacts are preserved.")
    output.mkdir(parents=True)
    if subprocess.run(["gh", "release", "view", args.tag], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0:
        raise SystemExit("This release tag already exists.")
    run(["python3", ROOT / "scripts/check_repo.py"], cwd=ROOT)
    run(["python3", ROOT / "scripts/check_public.py", "--history"], cwd=ROOT)
    run(["python3", ROOT / "scripts/build_runtime.py"], cwd=ROOT)
    run(["python3", ROOT / "scripts/build_ghostty.py"], cwd=ROOT)
    archive = output / "Spookky.xcarchive"
    run(["xcodebuild", "-project", ROOT / "Spookky.xcodeproj", "-scheme", "Spookky", "-configuration", "Distribution",
         "-destination", "generic/platform=macOS", "-archivePath", archive, "archive", "DEVELOPMENT_TEAM=" + args.team, "CODE_SIGN_IDENTITY=" + args.identity], cwd=ROOT)
    app = archive / "Products/Applications/Spookky.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key, expected in [("CFBundleIdentifier", config["bundleID"]), ("CFBundleVersion", str(config["build"])),
                          ("CFBundleShortVersionString", config["version"]), ("SUPublicEDKey", config["publicEDKey"]),
                          ("SUFeedURL", config["feedURL"]), ("SpookkyReleaseChannel", config["channel"]),
                          ("LSMinimumSystemVersion", config["minimumOS"])]:
        if info.get(key) != expected:
            raise SystemExit("Archived bundle differs from release metadata: " + key)
    for binary in (app / "Contents/MacOS").iterdir():
        if binary.is_file(): run(["strip", "-S", binary])
    run(["python3", ROOT / "scripts/verify_bundle.py", app])
    sign_nested(app, args.identity)
    temporary_zip = output / "notarization.zip"
    run(["ditto", "-c", "-k", "--keepParent", app, temporary_zip])
    submit_notarization(temporary_zip, args.notary_profile)
    run(["xcrun", "stapler", "staple", app])
    run(["spctl", "--assess", "--type", "execute", app])
    dmg = output / ("Spookky-" + args.tag[1:] + "-arm64.dmg")
    from create_dmg import create
    create(app, ROOT / "website/assets/dmg-background.tiff", dmg)
    run(["codesign", "--timestamp", "--sign", args.identity, dmg])
    notarize(dmg, args.notary_profile)
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg])
    updates = output / "updates"; updates.mkdir(); shutil.copy2(dmg, updates / dmg.name)
    notes = updates / (dmg.stem + ".md"); shutil.copy2(args.notes, notes)
    existing = ROOT / "website/appcast.xml"
    if existing.exists(): shutil.copy2(existing, updates / "appcast.xml")
    base = "https://github.com/Pamekitti/spookky/releases/download/" + args.tag + "/"
    command = signing_arguments(args.sparkle_tools / "generate_appcast") + ["--download-url-prefix", base,
        "--release-notes-url-prefix", base, "--maximum-deltas", "0", "--versions", str(config["build"])]
    if config["channel"] == "preview": command += ["--channel", "preview"]
    run(command + [updates])
    run(signing_arguments(args.sparkle_tools / "sign_update") + ["--verify", updates / "appcast.xml"])
    manifest = {"release": {"version": args.tag[1:], "build": config["build"], "channel": config["channel"],
        "minimumOS": config["minimumOS"], "architecture": "arm64", "assetURL": base + dmg.name,
        "bytes": dmg.stat().st_size, "sha256": hashlib.sha256(dmg.read_bytes()).hexdigest(),
        "notesURL": "https://github.com/Pamekitti/spookky/releases/tag/" + args.tag}}
    (output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "SHA256SUMS").write_text(manifest["release"]["sha256"] + "  " + dmg.name + "\n")
    print("Prepared signed artifacts. Complete the installation/update gates before publication.")


if __name__ == "__main__":
    main()
