"""Resolve the same private terminal runtime used by the native app."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def launch_helper_path(configuration=None):
    selected = (configuration or os.environ.get("SPOOKKY_TEST_CONFIGURATION", "debug")).lower()
    if selected not in {"debug", "release"}:
        raise ValueError("Helper configuration must be debug or release")
    override = os.environ.get("SPOOKKY_LAUNCH_HELPER")
    return Path(override) if override else ROOT / ".build" / selected / "spookky-launch"


def tmux_path():
    candidates = [os.environ.get("SPOOKKY_TMUX"), str(ROOT / ".cache/runtime/bin/tmux")]
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return str(ROOT / ".cache/runtime/bin/tmux")
