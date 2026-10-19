#!/usr/bin/env python3
"""Verify native new-session context, menus, input and shell preservation."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from benchmark_m0 import tree
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=NATIVE_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with native_fixture(["--workspace-benchmark-count", "0", "--workspace-benchmark-composer", "--workspace-benchmark-front"],
                        prefix="spookky-m1-composer-", binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(120, "Native composer check failed")
        except Exception:
            for source in fixture.root.glob("composer-*"):
                shutil.copy2(source, args.output.parent / source.name)
            shutil.copy2(fixture.root / "app.log", args.output.with_suffix(".log"))
            raise
        checks = json.loads((fixture.root / "composer-checks.json").read_text())
        resources = json.loads((fixture.root / "composer-resources.json").read_text())
        process_rows = {}
        for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,args="], text=True).splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) == 4:
                process_rows[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
        seeds = {fixture.process.pid}
        seeds.update(pid for pid, (_, _, command) in process_rows.items() if str(fixture.root / "socket") in command)
        owned = tree(process_rows, seeds)
        resources["runtime_and_shell_rss_mib"] = sum(rss for pid, (_, rss, _) in process_rows.items() if pid in owned and pid != fixture.process.pid) / 1024
        resources["total_session_rss_mib"] = resources["app_rss_mib"] + resources["runtime_and_shell_rss_mib"]
        screenshots = []
        for source in fixture.root.glob("composer-*.png"):
            destination = args.output.parent / source.name
            shutil.copy2(source, destination)
            screenshots.append(str(destination))
        report = {"checks": checks, "resources": resources, "screenshots": screenshots,
                  "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  "boundary": "Native AppKit controls and one disposable shell. Model catalog fixtures, no model turn. Physical typing and spoken VoiceOver remain separate."}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not checks or not all(checks.values()):
            raise SystemExit("Native composer check failed")


if __name__ == "__main__":
    main()
