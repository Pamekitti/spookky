#!/usr/bin/env python3
"""Build a local daily-app installer from main in a separate checkout."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, *, cwd=ROOT):
    subprocess.run([str(value) for value in arguments], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--open", action="store_true", help="Open the finished DMG for manual installation")
    args = parser.parse_args()
    if not all(importlib.util.find_spec(name) for name in ["ds_store", "mac_alias"]):
        raise SystemExit("Use the pinned release-tools Python. See docs/releasing.md.")
    run(["git", "fetch", "origin", "main"])
    commit = subprocess.check_output(["git", "rev-parse", "refs/remotes/origin/main"], cwd=ROOT, text=True).strip()
    output = ROOT / ".cache/main-updates" / commit
    source = ROOT / ".cache/main-update-sources" / commit
    if output.exists():
        raise SystemExit("This main commit already has installer output. Preserve it and inspect its result before retrying.")
    source.parent.mkdir(parents=True, exist_ok=True)
    if source.exists():
        checkout = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=source, text=True).strip()
        existing = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True).strip()
        if Path(checkout).resolve() != source.resolve() or existing != commit or dirty:
            raise SystemExit("The retained source checkout changed. Preserve it and inspect its work before retrying.")
    else:
        run(["git", "worktree", "add", "--detach", source, commit])
    print("Preparing main commit:", commit, flush=True)
    print("Source checkout retained at:", source, flush=True)
    # These builds are explicit preparation, never project registration or opening Local.
    run([sys.executable, "scripts/build_runtime.py"], cwd=source)
    run(["swift", "build", "--product", "spookky-launch"], cwd=source)
    run(["swift", "build", "--product", "spookky-runtime-check"], cwd=source)
    run(["swift", "test"], cwd=source)
    run([sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py"], cwd=source)
    run([sys.executable, "scripts/check_repo.py"], cwd=source)
    run([sys.executable, "scripts/build_ghostty.py"], cwd=source)
    run(["sh", "scripts/build_native.sh", "Release"], cwd=source)
    app = source / "DerivedData/Build/Products/Release/Spookky.app"
    run([sys.executable, "scripts/verify_bundle.py", app], cwd=source)
    actual = subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True).strip()
    if actual:
        raise SystemExit("Preparation changed tracked source. Inspect the retained checkout before packaging.")
    run([sys.executable, "scripts/prepare_local_dmg.py", "--app", app, "--source-commit", commit, "--output", output], cwd=source)
    print("Local installer prepared at:", output)
    print("Quit the daily app with Keep sessions running before replacing it in Applications.")
    if args.open:
        dmg = next(output.glob("*.dmg"))
        run(["/usr/bin/open", dmg])


if __name__ == "__main__":
    main()
