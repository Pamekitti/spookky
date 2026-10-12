#!/usr/bin/env python3
"""Check the current documentation and prototype handoff without dependencies."""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from render_prototype import ROOT, rendered_preview


def main() -> int:
    errors: list[str] = []
    required = [
        "README.md", "AGENTS.md", "CLAUDE.md", "COPYRIGHT", "THIRD_PARTY.md",
        "docs/product.md", "docs/flows.md", "docs/interface.md", "docs/architecture.md",
        "docs/acceptance.md", "docs/build-plan.md", "docs/performance.md",
        "docs/development.md", "docs/decisions/README.md", "docs/status.md",
        "prototype/spookky-workspace.html",
        "prototype/spookky-before-polish.html", "prototype/index.html",
        "prototype/preview-template.html", "prototype/README.md",
    ]
    for name in required:
        if not (ROOT / name).is_file():
            errors.append(f"Missing required file: {name}")

    docs = list(ROOT.glob("*.md")) + list((ROOT / "docs").rglob("*.md"))
    docs += list((ROOT / "prototype").glob("*.md"))
    link_count = 0
    for path in docs:
        for raw in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", path.read_text()):
            target = raw.strip().strip("<>")
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            link_count += 1
            if not (path.parent / unquote(parsed.path)).exists():
                errors.append(f"Broken local link in {path.relative_to(ROOT)}: {target}")

    try:
        if (ROOT / "prototype/index.html").read_text() != rendered_preview():
            errors.append("Preview is stale. Run python3 scripts/render_prototype.py")
    except (OSError, ValueError) as error:
        errors.append(str(error))

    source = ROOT / "prototype/spookky-workspace.html"
    node = shutil.which("node")
    if node and source.exists():
        scripts = re.findall(r"<script>([\s\S]*?)</script>", source.read_text())
        if not scripts:
            errors.append("Prototype has no inline script to check")
        with tempfile.TemporaryDirectory(prefix="spookky-syntax-") as directory:
            for index, script in enumerate(scripts):
                temporary = Path(directory) / f"prototype-{index}.js"
                temporary.write_text(script)
                result = subprocess.run([node, "--check", str(temporary)], capture_output=True, text=True)
                if result.returncode:
                    errors.append(result.stderr.strip())
        print(f"JavaScript syntax: checked {len(scripts)} script(s)")
    else:
        print("JavaScript syntax: skipped (Node.js unavailable)")

    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"PASS: {len(required)} required files, {link_count} local links, synchronized preview")
    print("Native app and browser interaction tests were not run by this checker.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
