#!/usr/bin/env python3
"""Run the checks relevant to this change once before shipping."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

from check_scope import ROOT, changed_paths, classify


def fingerprint(selected, *, root=ROOT):
    digest = hashlib.sha256()
    context = {key: value for key, value in os.environ.items() if key.startswith("SPOOKKY_") or key in {"PATH", "DEVELOPER_DIR"}}
    digest.update(json.dumps([str(root.resolve()), sys.version, platform.platform(), selected, context], sort_keys=True).encode())
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    for name in sorted(set(names) - {""}):
        path = root / name
        digest.update(name.encode() + b"\0")
        digest.update(os.readlink(path).encode() if path.is_symlink() else path.read_bytes() if path.is_file() else b"deleted")
    if any(command[0] == "swift" for command in selected):
        for command in [["swift", "--version"], ["xcodebuild", "-version"]]:
            digest.update(subprocess.check_output(command))
        runtime = Path(os.environ.get("SPOOKKY_TMUX", str(root / ".cache/runtime/bin/tmux")))
        libraries = list((root / ".cache/dependencies/ghostty/macos/GhosttyKit.xcframework").rglob("*.a"))
        for path in [runtime, *sorted(libraries)]:
            if path.is_file():
                with path.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
    if any(command[0] == "npm" for command in selected):
        for command in [["node", "--version"], ["npm", "--version"]]:
            digest.update(subprocess.check_output(command))
    return digest.hexdigest()


def commands(scope):
    selected = [[sys.executable, "scripts/check_repo.py"],
                [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py"]]
    if scope["local_native"]:
        selected.append(["swift", "test"])
        if scope["packaging"]:
            selected.append(["sh", "scripts/build_native.sh", "Debug"])
        selected.extend([["sh", "scripts/build_native.sh", "Release"],
                         [sys.executable, "scripts/verify_bundle.py", "DerivedData/Build/Products/Release/Spookky.app"],
                         ["codesign", "--verify", "--deep", "--strict", "DerivedData/Build/Products/Release/Spookky.app"]])
    if scope["website"]:
        selected.append(["npm", "test", "--prefix", "website"])
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--full", action="store_true", help="Run all local checks")
    parser.add_argument("--plan", action="store_true", help="Print selected commands without running them")
    parser.add_argument("--force", action="store_true", help="Rerun checks even when this exact source and command set passed")
    args = parser.parse_args()
    paths, unknown = changed_paths(args.base)
    scope = classify(paths, unknown_base=unknown or args.full)
    selected = commands(scope)
    if args.plan:
        print(json.dumps({"files": paths, **scope, "commands": selected}, indent=2))
        return
    key = fingerprint(selected, root=ROOT)
    receipt = ROOT / ".cache/checks/last.json"
    if receipt.exists() and not args.force:
        try:
            saved = json.loads(receipt.read_text())
        except (OSError, ValueError):
            saved = {}
        if not isinstance(saved, dict):
            saved = {}
        if saved.get("key") == key:
            print(f"Reused {len(selected)} passed check commands for the unchanged source and environment.")
            return
    receipt.unlink(missing_ok=True)
    started = time.monotonic()
    for command in selected:
        print("Check:", " ".join(command), flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
    elapsed = time.monotonic() - started
    if fingerprint(selected, root=ROOT) != key:
        raise SystemExit("Source changed during verification. Rerun checks before shipping.")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    temporary = receipt.with_name(f".receipt-{os.getpid()}.json")
    temporary.write_text(json.dumps({"key": key, "commands": selected, "seconds": elapsed}, indent=2) + "\n")
    temporary.replace(receipt)
    print(f"Passed {len(selected)} check commands in {elapsed:.1f}s.")


if __name__ == "__main__":
    main()
