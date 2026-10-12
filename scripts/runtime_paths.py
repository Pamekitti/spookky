"""Resolve the same private terminal runtime used by the native app."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def tmux_path():
    candidates = [os.environ.get("SPOOKKY_TMUX"), str(ROOT / ".cache/runtime/bin/tmux")]
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return str(ROOT / ".cache/runtime/bin/tmux")
