#!/usr/bin/env python3
"""Measure the real M1 window using disposable shells and owned runtime roots."""
import argparse
import hashlib
import json
import platform
import os
import sqlite3
import statistics
import subprocess
import time
import uuid
from pathlib import Path

from benchmark_m0 import processes, tree, summarize
from native_fixture import NATIVE_BINARY, TMUX, native_fixture


def request_cpu(fixture):
    request = str(uuid.uuid4())
    pending = fixture.root / "cpu-request.pending"
    pending.write_text(request)
    pending.replace(fixture.root / "cpu-request")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            sample = json.loads((fixture.root / "workspace-cpu.json").read_text())
            if sample["request"] == request: return sample
        except (OSError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(0.02)
    raise RuntimeError("CPU observation did not arrive.")


def resources(count, seconds, split=False, foreground=False):
    arguments = ["--workspace", "--workspace-measure", "--workspace-benchmark-count", str(count)]
    if split: arguments.append("--workspace-benchmark-split")
    if foreground: arguments.append("--workspace-benchmark-front")
    with native_fixture(arguments,
                        prefix="spookky-m1-bench-", workspace=True) as fixture:
        fixture.wait_ready(90, "Workspace fixture did not become ready.")
        return measure_settled(fixture, count, seconds, split, foreground)


def measure_settled(fixture, count, seconds, split=False, foreground=False):
    time.sleep(5)
    server = int(subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "display-message", "-p", "#{pid}"], text=True)) if count else None
    initial = processes()
    clients = set(map(int, subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "list-clients", "-F", "#{client_pid}"], text=True).split())) if count else set()
    footprint = subprocess.run(["vmmap", "-summary", str(fixture.process.pid)], capture_output=True, text=True)
    footprint_lines = [line.strip() for line in footprint.stdout.splitlines() if "Physical footprint" in line]
    cpu_before = request_cpu(fixture)
    def owned(table):
        return ({fixture.process.pid} | clients | (tree(table, [server]) if server else set())) & table.keys()
    before = owned(initial)
    start = time.monotonic()
    samples, stable = [], True
    while time.monotonic() - start < seconds:
        table = processes(); members = owned(table)
        stable = stable and members == before
        samples.append({"app_rss_mib": table[fixture.process.pid][1] / 1024,
                        "total_rss_mib": sum(table[p][1] for p in members) / 1024})
        time.sleep(0.2)
    final = processes(); elapsed = time.monotonic() - start
    cpu_after = request_cpu(fixture)
    stable = stable and owned(final) == before
    app_delta = final[fixture.process.pid][2] - initial[fixture.process.pid][2]
    runtime_delta = sum(final[p][2] - initial[p][2] for p in before if p in final and p != fixture.process.pid)
    child_delta = cpu_after["children_cpu_seconds"] - cpu_before["children_cpu_seconds"]
    delta = app_delta + runtime_delta + child_delta
    ready = json.loads((fixture.root / "ready.json").read_text())
    return {"sessions": count, "metric": "RSS summed across distinct app/runtime/clean-shell processes",
            "warmup_seconds": 5, "elapsed_seconds": elapsed, "sample_count": len(samples),
            "app_rss_mib_median": statistics.median(s["app_rss_mib"] for s in samples),
            "total_rss_mib_median": statistics.median(s["total_rss_mib"] for s in samples),
            "surface_count": ready["surface_count"],
            "split": split, "app_physical_footprint_observation": footprint_lines,
            "physical_footprint_available": footprint.returncode == 0 and bool(footprint_lines),
            "requested_foreground": foreground,
            "visible_at_cpu_boundaries": [cpu_before.get("window_visible"), cpu_after.get("window_visible")],
            "active_at_cpu_boundaries": [cpu_before.get("app_active"), cpu_after.get("app_active")],
            "stable_process_set": stable, "failure_count": 0 if stable else 1,
            "idle_cpu_percent_one_core": 100 * delta / elapsed if stable else None,
            "app_cpu_seconds": app_delta, "live_runtime_cpu_seconds": runtime_delta,
            "reaped_child_cpu_seconds": child_delta,
            "child_cpu_observation_span_seconds": cpu_after["monotonic_seconds"] - cpu_before["monotonic_seconds"],
            "cpu_boundary_note": "Reaped app children include runtime queries triggered by lifecycle events. Boundary snapshots are requested once before and after the observation through a directory-event watcher. Its timestamps are reported separately from the ps boundaries. Live app clients and private server/shells are counted separately."}


def timing(resize=False, *, binary=NATIVE_BINARY, extra_arguments=(), prepare=None):
    arguments = ["--workspace", "--workspace-measure", "--workspace-benchmark-count", "4", "--workspace-benchmark-timing", *extra_arguments]
    if resize: arguments.append("--workspace-benchmark-resize")
    with native_fixture(arguments,
                        prefix="spookky-m1-timing-", binary=binary, prepare=prepare, workspace=True) as fixture:
        fixture.wait_ready(180, "Workspace timing did not finish.")
        time.sleep(0.3)
        rows = json.loads((fixture.root / "workspace-timings.json").read_text())
        result = {}
        if resize:
            checks = json.loads((fixture.root / "resize-checks.json").read_text())
            result["wrapped_resize"] = {"checks": checks, "failure_count": sum(not value for value in checks.values())}
        for name, warm in [("warm_selection", True), ("recreated_surface_selection", False)]:
            selected = [r["value"] for r in rows if r["warm"] == warm][5:]
            memory = [r["residentMiB"] for r in rows if r["warm"] == warm and r.get("residentMiB") is not None][5:]
            block = max(1, len(memory) // 3)
            result[name] = {**summarize(selected), "failure_count": 0,
                            "rss_mib_by_selection": memory,
                            "rss_mib_first_middle_last_medians": [statistics.median(memory[:block]), statistics.median(memory[block:2*block]), statistics.median(memory[2*block:])] if len(memory) >= 3 else [],
                            "maximum_surface_count": max(r["surfaceCount"] for r in rows),
                            "boundary": "Workspace selection to attached, laid out and focused native view. Excludes first terminal bytes and rendered-display latency."}
        expected = json.loads((fixture.root / "fixture-history.json").read_text())["expected_history_marker"]
        def identities():
            return subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "list-panes", "-a", "-F", "#{session_name} #{pane_pid}"], text=True)
        before = identities()
        fixture.process.kill(); fixture.process.wait()
        environment = dict(os.environ, SPOOKKY_M1_ROOT=str(fixture.root), SPOOKKY_M1_DATA=str(fixture.root / "metadata"))
        with (fixture.root / "app.log").open("a") as log:
            fixture.process = subprocess.Popen([str(binary), "--workspace", "--workspace-measure", "--workspace-benchmark-restoring", *extra_arguments], env=environment, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            restored = None
            while time.monotonic() < deadline:
                try:
                    observed = request_cpu(fixture)
                    if observed["pid"] == fixture.process.pid and observed.get("history_marker") == expected:
                        restored = observed; break
                except (OSError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            state = json.loads(sqlite3.connect(fixture.root / "metadata/workspace.sqlite").execute("SELECT payload FROM workspace_snapshot").fetchone()[0])
            checks = {"same_processes": before == identities(), "same_visible_history_marker": restored is not None,
                      "no_extra_workspace": len(state["workspaces"]) == 1,
                      "no_extra_tabs": len(state["workspaces"][0]["tabs"]) == 4}
            result["crash_restore"] = {"checks": checks, "failure_count": sum(not value for value in checks.values()),
                                      "expected_history_marker": expected, "boundary": "Real app crash and metadata reload, private process identities, and Ghostty terminal-state viewport. Not rendered-display latency."}
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--mode", choices=["resources", "timing", "all"], default="all")
    parser.add_argument("--sessions", nargs="+", type=int, choices=[0, 1, 5, 10], default=[0, 1, 5, 10])
    parser.add_argument("--split", action="store_true")
    parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--resize", action="store_true")
    parser.add_argument("--output", default=".cache/m1-benchmarks.json")
    args = parser.parse_args()
    if args.seconds < 1: parser.error("--seconds must be positive")
    report = {"binary_sha256": hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest(), "host": platform.platform(),
              "cpu_note": "Cumulative CPU-time difference across stable long-lived owned processes plus reaped app-child CPU, divided by elapsed time. 100% equals one core; collector excluded. RSS includes shared pages and is affected by compression.",
              "fixture_note": "Clean zsh -f shells, one visible terminal and at most one warm hidden surface. Window is visible in the background. Opt-in diagnostics are included in app costs."}
    path = Path(args.output); path.parent.mkdir(parents=True, exist_ok=True)
    if args.mode != "timing":
        report["resources"] = []
        for count in args.sessions:
            row = resources(count, args.seconds, args.split, args.foreground); report["resources"].append(row)
            path.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(row), flush=True)
    if args.mode != "resources": report["timing"] = timing(args.resize)
    report["binary_changed_during_run"] = hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest() != report["binary_sha256"]
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(str(path), flush=True)
    if report["binary_changed_during_run"] or any(r["failure_count"] for r in report.get("resources", [])) or any(r["failure_count"] for r in report.get("timing", {}).values()):
        raise SystemExit("Benchmark contains a failed check; inspect results.")


if __name__ == "__main__":
    main()
