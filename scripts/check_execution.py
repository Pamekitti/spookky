"""Common command execution and non-empty discovery checks."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def require_discovered(count, suite):
    if count < 1:
        raise RuntimeError("No tests discovered for " + suite)


def run(command, *, env=None, capture=False, evidence=None):
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture or evidence else None,
        stderr=subprocess.STDOUT if capture or evidence else None,
    )
    if evidence:
        Path(evidence).write_text(result.stdout or "")
    if capture or evidence:
        print(result.stdout, end="", flush=True)
    result.check_returncode()
    return result.stdout or ""
