#!/usr/bin/env python3
"""Rebuild the standalone preview from the checked-in fragment and wrapper."""

from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = "<!-- SPOOKKY_PROTOTYPE_SOURCE -->"


def rendered_preview() -> str:
    template = (ROOT / "prototype/preview-template.html").read_text()
    if template.count(MARKER) != 1:
        raise ValueError("Preview template must contain exactly one source marker")
    source = (ROOT / "prototype/spookky-workspace.html").read_text()
    return template.replace(MARKER, escape(source))


if __name__ == "__main__":
    output = ROOT / "prototype/index.html"
    output.write_text(rendered_preview())
    print("Rendered prototype/index.html")
