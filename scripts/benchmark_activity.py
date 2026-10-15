#!/usr/bin/env python3
"""Measure activity indicators and the waiting helper in isolated native fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import tempfile
import time
import uuid

from benchmark_m0 import processes
from benchmark_m1 import measure_settled
from check_agent_hooks import private_json
from native_fixture import NATIVE_BINARY, native_fixture


def indicators(count, seconds, active, foreground):
    arguments = ["--workspace", "--workspace-measure", "--workspace-benchmark-count", str(count)]
    if active:
        arguments.append("--workspace-benchmark-activity")
    if foreground:
        arguments.append("--workspace-benchmark-front")
    with native_fixture(arguments, prefix="spookky-m1-activity-", workspace=True) as fixture:
        fixture.wait_ready(120, "Activity fixture did not become ready.")
        row = measure_settled(fixture, count, seconds, foreground=foreground)
        row["reported_activity"] = active
        return row


def waiting_helper(seconds):
    helper = NATIVE_BINARY.parent / "spookky-launch"
    with tempfile.TemporaryDirectory(prefix="spookky-helper-", dir="/tmp") as directory:
        root = Path(directory)
        executable = root / "codex"
        executable.write_text("#!/usr/bin/python3\n" + """
import os, pathlib, signal, sys
if '--help' in sys.argv:
    print('--dangerously-bypass-hook-trust'); sys.exit(0)
if '--version' in sys.argv:
    print('codex-cli 0.162.1'); sys.exit(0)
pathlib.Path(os.environ['SPOOKKY_HELPER_READY']).write_text(str(os.getpid()))
signal.pause()
""")
        executable.chmod(0o700)
        binding = str(uuid.uuid4()).upper()
        context = dict(bindingID=binding, secret=str(uuid.uuid4()).upper(), root=str(root), helper=str(helper))
        path = root / f"agent-terminal-{binding}.json"
        private_json(path, context)
        environment = {key: value for key, value in os.environ.items() if key != "SPOOKKY_AGENT_OWNER"}
        environment.update(SPOOKKY_ACTIVITY_CONTEXT=str(path), SPOOKKY_HELPER_READY=str(root / "ready"))
        process = subprocess.Popen([str(helper), "--agent-run", "codex", "--executable", str(executable), "--"],
                                   env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while not (root / "ready").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Waiting helper fixture did not become ready.")
                time.sleep(0.05)
            time.sleep(2)
            child = int((root / "ready").read_text())
            initial = processes(); started = time.monotonic(); samples = []
            while time.monotonic() - started < seconds:
                table = processes()
                if process.pid not in table or child not in table:
                    raise RuntimeError("Waiting helper fixture exited during measurement.")
                samples.append(table[process.pid][1] / 1024)
                time.sleep(0.2)
            final = processes(); elapsed = time.monotonic() - started
            return {"helper_rss_mib_median": statistics.median(samples), "sample_count": len(samples),
                    "helper_idle_cpu_percent_one_core": 100 * (final[process.pid][2] - initial[process.pid][2]) / elapsed,
                    "elapsed_seconds": elapsed, "extra_waiting_processes_per_cli": 1,
                    "boundary": "Packaged Release waiting helper with an idle fake CLI; provider process and callback bursts excluded."}
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--sessions", type=int, nargs="+", choices=[1, 5, 10], default=[1, 5, 10])
    parser.add_argument("--foreground", action="store_true", help="Keep each owned fixture visible and active during measurement")
    parser.add_argument("--output", type=Path, default=Path(".cache/activity-benchmarks.json"))
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error("--seconds must be positive")
    report = {"host": platform.platform(), "binary_sha256": hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest(),
              "boundary": "Clean shells with no agent state versus simulated provider states; both include the activity receiver. One visible terminal, at most one warm hidden surface. Foreground/visibility observations are recorded per case. No provider/model costs are included.",
              "resources": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for count in args.sessions:
        for active in [False, True]:
            row = indicators(count, args.seconds, active, args.foreground)
            report["resources"].append(row)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({key: row[key] for key in ["sessions", "reported_activity", "app_rss_mib_median", "total_rss_mib_median", "idle_cpu_percent_one_core", "stable_process_set"]}), flush=True)
    report["waiting_helper"] = waiting_helper(args.seconds)
    report["binary_changed_during_run"] = hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest() != report["binary_sha256"]
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["waiting_helper"]), flush=True)
    if report["binary_changed_during_run"] or any(row["failure_count"] for row in report["resources"]):
        raise SystemExit("Activity measurements contain a failed check.")


if __name__ == "__main__":
    main()
