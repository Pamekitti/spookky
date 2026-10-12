#!/usr/bin/env python3
"""Measure owned resource costs and native terminal readiness with isolated fixtures."""
import argparse
import hashlib
import json
import math
import platform
from pathlib import Path
import statistics
import subprocess
import time

from native_fixture import NATIVE_BINARY, TMUX, native_fixture


def cpu_seconds(value):
    days, clock = value.split("-", 1) if "-" in value else ("0", value)
    total = 0.0
    for part in clock.split(":"):
        total = total * 60 + float(part)
    return int(days) * 86400 + total


def processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time="], text=True)
    return {int(pid): (int(ppid), int(rss), cpu_seconds(cpu)) for pid, ppid, rss, cpu in (line.split() for line in output.splitlines())}


def tree(table, seeds):
    result = set(seeds)
    while True:
        added = {pid for pid, (ppid, _, _) in table.items() if ppid in result} - result
        if not added:
            return result
        result |= added


def run_case(binary, count, retain, seconds):
    arguments = ["--benchmark-count", str(count)] + (["--retain"] if retain else [])
    with native_fixture(arguments, prefix="spookky-bench-", binary=binary) as fixture:
        fixture.wait_ready(60, "Native benchmark did not become ready.")
        root, process = fixture.root, fixture.process
        time.sleep(5)
        server = None
        dimensions = []
        if count:
            server = int(subprocess.check_output([TMUX, "-S", str(root / "socket"), "display-message", "-p", "#{pid}"], text=True))
            dimensions = subprocess.check_output([TMUX, "-S", str(root / "socket"), "list-panes", "-a", "-F", "#{pane_width}x#{pane_height}"], text=True).splitlines()
        footprint = subprocess.run(["vmmap", "-summary", str(process.pid)], capture_output=True, text=True)
        footprint_lines = [line.strip() for line in footprint.stdout.splitlines() if "Physical footprint" in line]
        samples = []
        initial = processes()
        initial_pids = tree(initial, [process.pid]) | (tree(initial, [server]) if server else set())
        initial_pids &= initial.keys()
        started = time.monotonic()
        stable = True
        while time.monotonic() - started < seconds:
            table = processes()
            app_tree = tree(table, [process.pid])
            runtime_tree = tree(table, [server]) if server else set()
            owned = app_tree | runtime_tree
            owned &= table.keys()
            stable = stable and owned == initial_pids
            samples.append({
                "app_rss_mib": table.get(process.pid, (0, 0, 0))[1] / 1024,
                "total_rss_mib": sum(table[pid][1] for pid in owned if pid in table) / 1024,
                "cumulative_cpu_seconds": sum(table[pid][2] for pid in owned),
                "elapsed_seconds": time.monotonic() - started,
                "process_count": len(owned),
            })
            time.sleep(0.2)
        final = processes()
        elapsed = time.monotonic() - started
        final_pids = (tree(final, [process.pid]) | (tree(final, [server]) if server else set())) & final.keys()
        stable = stable and final_pids == initial_pids
        cpu_delta = sum(final[pid][2] - initial[pid][2] for pid in initial_pids if pid in final)
        return {
            "sessions": count, "retention": "retain" if retain else "release",
            "metric": "RSS, summed across distinct app/runtime/shell processes",
            "sample_count": len(samples), "minimum_sample_interval_seconds": 0.2,
            "warmup_seconds": 5, "dimensions": dimensions,
            "app_physical_footprint_observation": footprint_lines,
            "app_rss_mib_median": statistics.median(s["app_rss_mib"] for s in samples),
            "total_rss_mib_median": statistics.median(s["total_rss_mib"] for s in samples),
            "total_rss_mib_max": max(s["total_rss_mib"] for s in samples),
            "idle_cpu_seconds": cpu_delta if stable else None,
            "idle_elapsed_seconds": elapsed,
            "idle_cpu_percent_one_core": 100 * cpu_delta / elapsed if stable else None,
            "stable_process_set": stable,
            "failure_count": 0 if stable else 1,
            "samples": samples,
        }


def summarize(samples):
    ordered = sorted(samples)
    return {"sample_count": len(ordered), "median_ms": statistics.median(ordered),
            "p95_ms": ordered[math.ceil(0.95 * len(ordered)) - 1]}


def run_timing(binary):
    startups = []
    for _ in range(30):
        start = time.monotonic()
        with native_fixture(["--benchmark-count", "0"], prefix="spookky-start-", binary=binary) as fixture:
            fixture.wait_ready(60, "Startup failed.", poll_interval=0.005)
            ready = json.loads((fixture.root / "ready.json").read_text())
            startups.append({"spawn_to_ready_ms": (time.monotonic() - start) * 1000,
                             "main_to_ready_ms": ready["main_to_ready_ms"]})
    with native_fixture(["--benchmark-timing"], prefix="spookky-timing-", binary=binary) as fixture:
        fixture.wait_ready(420, "Timing check did not finish.")
        timing = json.loads((fixture.root / "timing.json").read_text())
    result = {"startup": {**summarize([s["spawn_to_ready_ms"] for s in startups]),
                           "failure_count": 0, "samples": startups,
                           "boundary": "Before process spawn to observed empty-app ready receipt; 5 ms polling. Not first frame or shell readiness."}}
    for name, checks in [("reattachment", ["draft_preserved", "same_process", "one_client"]),
                         ("terminal_state_echo", ["echoed"])]:
        rows = timing[name]
        result[name] = {**summarize([r["milliseconds"] for r in rows]), "samples": rows,
                        "failure_count": sum(not all(r[c] == 1 for c in checks) for r in rows)}
    result["reattachment"]["boundary"] = "Before releasing view to draft visible in terminal state; PID/client checked outside timing."
    result["terminal_state_echo"]["boundary"] = "Native insertText call to text visible in terminal state; unloaded cat fixture, 2 ms polling. Not physical key-to-display latency."
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--mode", choices=["resources", "timing", "all"], default="all")
    parser.add_argument("--output", default=".cache/m0-benchmarks.json")
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error("--seconds must be positive")
    binary = NATIVE_BINARY
    if not binary.exists():
        raise SystemExit("Build the Release native app first.")
    report = {"binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "host": platform.platform(),
              "cpu_note": "Delta of ps cumulative CPU time across a stable owned process set divided by monotonic elapsed time; 100% is one core. ps has centisecond resolution. Collector is excluded."}
    destination = Path(args.output)
    def save():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(report, indent=2) + "\n")
    if args.mode in ["resources", "all"]:
        report["results"] = []
        for count in [0, 1, 5, 10]:
            result = run_case(binary, count, False, args.seconds)
            report["results"].append(result)
            save()
            print(f"{count} sessions: {result['total_rss_mib_median']:.1f} MiB RSS, idle CPU {result['idle_cpu_percent_one_core']}% of one core", flush=True)
    if args.mode in ["timing", "all"]:
        report["timing"] = run_timing(binary)
        save()
        print(json.dumps({k: {f: v[f] for f in ["sample_count", "median_ms", "p95_ms", "failure_count"]} for k, v in report["timing"].items()}), flush=True)
    if any(r["failure_count"] for r in report.get("results", [])) or any(r["failure_count"] for r in report.get("timing", {}).values()):
        raise SystemExit("Benchmark contains failed checks; inspect the report.")


if __name__ == "__main__":
    main()
