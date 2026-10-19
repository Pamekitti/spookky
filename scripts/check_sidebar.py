#!/usr/bin/env python3
"""Check native sidebar navigation and keyboard reveal in disposable state."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from native_fixture import NATIVE_BINARY, TMUX, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=NATIVE_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--display", action="store_true")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    with native_fixture(["--workspace-benchmark-count", "0", "--workspace-benchmark-sidebar", "--workspace-benchmark-front"] + (["--workspace-benchmark-display"] if args.display else []),
                        prefix="spookky-m1-sidebar-check-", binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(100, "Native sidebar check failed")
        except Exception:
            evidence = fixture.preserve_evidence(args.output, ["app.log", "sidebar-checks.json", "sidebar-resources.json", "sidebar-interaction-diagnostics.json", "sidebar-dark.png", "sidebar-light.png", "display-checks.json", "display-hit-details.json", "fullscreen-transition-failure.json", "display-*.png"])
            print("Sidebar failure evidence: " + str(evidence), flush=True)
            raise
        for source in fixture.root.glob("display-*.png"):
            shutil.copy2(source, args.output.parent / source.name)
        checks = json.loads((fixture.root / "sidebar-checks.json").read_text())
        resources = json.loads((fixture.root / "sidebar-resources.json").read_text())
        processes = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,command="], text=True).splitlines()
        rows = [row.split(None, 3) for row in processes]
        rows = [(int(pid), int(parent), int(rss), command) for pid, parent, rss, command in rows]
        pane_pids = subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "list-panes", "-a", "-F", "#{pane_pid}"], text=True).splitlines()
        owned = {int(pid) for pid in pane_pids}
        owned.update(pid for pid, _, _, command in rows if str(fixture.root / "socket") in command)
        previous = set()
        while previous != owned:
            previous = set(owned)
            owned.update(pid for pid, parent, _, _ in rows if parent in owned)
        runtime_kib = sum(rss for pid, _, rss, _ in rows if pid in owned)
        app_kib = next(rss for pid, _, rss, _ in rows if pid == fixture.process.pid)
        resources["app_rss_mib_at_ready"] = app_kib / 1024
        resources["runtime_and_shell_rss_mib"] = runtime_kib / 1024
        resources["total_session_rss_mib"] = (app_kib + runtime_kib) / 1024
        screenshots = []
        for theme in ["dark", "light"]:
            destination = args.output.with_name(args.output.stem + "-" + theme + ".png")
            shutil.copyfile(fixture.root / ("sidebar-" + theme + ".png"), destination)
            screenshots.append(str(destination))
        report = {"binary_sha256": digest, "checks": checks, "screenshots": screenshots,
                  "resources": resources,
                  "boundary": "Native AppKit actions and focus in disposable state. Physical pointer and spoken VoiceOver checks remain separate."}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not checks or not all(checks.values()):
            raise SystemExit("Native sidebar check failed")


if __name__ == "__main__":
    main()
