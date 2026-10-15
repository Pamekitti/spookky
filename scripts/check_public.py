#!/usr/bin/env python3
"""Audit publishable files and secret-scan the working tree or Git history."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    ("Darwin", "arm64"): ("darwin_arm64", "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"),
    ("Linux", "x86_64"): ("linux_x64", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"),
}


def gitleaks():
    target, digest = PINS[(platform.system(), platform.machine())]
    directory = ROOT / ".cache/gitleaks"
    binary = directory / "gitleaks"
    if not binary.exists():
        directory.mkdir(parents=True, exist_ok=True)
        archive = directory / "download.tar.gz"
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", f"https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_{target}.tar.gz", "-o", str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise SystemExit("Secret scanner checksum mismatch.")
        with tarfile.open(archive) as content:
            content.extractall(directory, filter="data")
    return binary


def has_note_refs(refs):
    return any(ref.startswith("refs/notes/") or re.match(r"refs/(?:audit|remotes)/[^/]+/notes/", ref) for ref in refs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--history", action="store_true")
    args = parser.parse_args()
    git = ["/usr/bin/git", "-c", "trace2.eventTarget=0"]
    files = subprocess.check_output(git + ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    errors = []
    prohibited = re.compile(r"(?:/Users/[^/\s]+/(?:Documents|\.codex|Library)|BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY)")
    for name in sorted(set(files) - {""}):
        if name.startswith(("reports/local/", ".cache/", ".cache-")) or name.endswith((".sqlite", ".sqlite-wal", ".p12", ".pem", ".key", ".log")):
            errors.append("Private artifact in publishable files: " + name)
            continue
        path = ROOT / name
        try:
            text = path.read_text()
        except (UnicodeError, OSError):
            continue
        if prohibited.search(text):
            errors.append("Private material in " + name)
    refs = subprocess.check_output(git + ["for-each-ref", "--format=%(refname)"], cwd=ROOT).decode().splitlines()
    if has_note_refs(refs):
        errors.append("Git notes must remain outside public refs.")
    if errors:
        raise SystemExit("\n".join(errors))
    tool = str(gitleaks())
    config = ["--config", str(ROOT / ".gitleaks.toml")]
    # A sanitized copy excludes ignored caches and development state from the scan.
    import tempfile
    import shutil
    with tempfile.TemporaryDirectory(prefix="spookky-public-") as temporary:
        for name in set(files) - {""}:
            source = ROOT / name
            if source.is_file():
                destination = Path(temporary) / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
        subprocess.run([tool, "dir", temporary, "--redact", "--no-banner", "--report-format", "json", "--report-path", str(ROOT / ".cache/public-scan.json")] + config, check=True)
    if args.history:
        subprocess.run([tool, "git", "--log-opts=--all", "--redact", "--no-banner", str(ROOT)] + config, check=True, env=dict(os.environ, GIT_TRACE2_EVENT="0", PATH="/usr/bin:/bin:" + os.environ.get("PATH", "")))
    print("Public file and ref audit passed.")


if __name__ == "__main__":
    main()
