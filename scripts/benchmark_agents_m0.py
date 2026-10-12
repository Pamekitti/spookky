#!/usr/bin/env python3
"""Measure app/runtime overhead separately from owned idle agent CLI descendants."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import time

from benchmark_m0 import processes, tree
from native_fixture import NATIVE_BINARY, ROOT, TMUX, native_fixture


def memory_available_percent():
    output = subprocess.check_output(["/usr/bin/memory_pressure", "-Q"], text=True)
    match = re.search(r"free percentage:\s*(\d+)%", output)
    if not match:
        raise RuntimeError("Could not read the host memory-pressure boundary.")
    return int(match[1])


def groups(table, app, server, agent_pids):
    owned = (tree(table, [app]) | tree(table, [server])) & table.keys()
    agents = set().union(*(tree(table, [pid]) for pid in agent_pids)) & owned
    return {"app_runtime": owned - agents, "agents": agents, "total": owned}


def run_case(provider, count, seconds):
    if memory_available_percent() < 10:
        raise RuntimeError("Host memory pressure is too high to launch more fixtures. No user process was stopped.")
    with native_fixture(["--benchmark-agent-count", str(count), "--benchmark-provider", provider], prefix="spookky-agent-bench-") as fixture:
        fixture.wait_ready(120, "Agent benchmark failed to become ready.")
        rows = json.loads((fixture.root / "agent-benchmark.json").read_text())
        if len(rows) != count or any(row["dead"] for row in rows):
            raise RuntimeError("An agent CLI exited during launch; no settled measurement is valid.")
        roots = [row["pid"] for row in rows]
        server = int(subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "display-message", "-p", "#{pid}"], text=True))
        time.sleep(15)
        initial = processes()
        if not all(pid in initial for pid in roots):
            raise RuntimeError("An agent frontend exited during warm-up; the case is incomplete.")
        dimensions = subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), "list-panes", "-a", "-F", "#{pane_width}x#{pane_height}"], text=True).splitlines()
        initial_groups = groups(initial, fixture.process.pid, server, roots)
        start = time.monotonic()
        samples = []
        stable = {name: True for name in initial_groups}
        minimum_memory = memory_available_percent()
        next_memory_check = start
        while time.monotonic() - start < seconds:
            if fixture.process.poll() is not None:
                raise RuntimeError("Native app exited during measurement.")
            table = processes()
            current = groups(table, fixture.process.pid, server, roots)
            for name in current:
                stable[name] = stable[name] and current[name] == initial_groups[name]
            samples.append({"elapsed_seconds": time.monotonic() - start,
                            **{name + "_rss_mib": sum(table[pid][1] for pid in pids) / 1024 for name, pids in current.items()},
                            "app_rss_mib": table[fixture.process.pid][1] / 1024,
                            "owned_process_count": len(current["total"])})
            if time.monotonic() >= next_memory_check:
                minimum_memory = min(minimum_memory, memory_available_percent())
                if minimum_memory < 10:
                    raise RuntimeError("Stopped owned fixtures because host memory pressure crossed the 10% boundary.")
                next_memory_check = time.monotonic() + 5
            time.sleep(0.2)
        final = processes()
        if not all(pid in final for pid in roots):
            raise RuntimeError("An agent frontend exited during measurement; the case is incomplete.")
        elapsed = time.monotonic() - start
        final_groups = groups(final, fixture.process.pid, server, roots)
        cpu = {}
        for name, pids in initial_groups.items():
            stable[name] = stable[name] and final_groups[name] == pids
            delta = sum(final[pid][2] - initial[pid][2] for pid in pids if pid in final)
            cpu[name] = 100 * delta / elapsed if stable[name] else None
        return {"provider_mix": provider, "sessions": count,
                "agents_by_tool": {tool: sum(row["tool"] == tool for row in rows) for tool in ["codex", "claude"]},
                "warmup_seconds": 15, "observation_seconds": elapsed, "sample_count": len(samples),
                "dimensions": dimensions,
                "metric": "RSS summed across distinct owned processes. Shared pages may be counted repeatedly; not physical footprint.",
                "medians_mib": {key: statistics.median(row[key] for row in samples) for key in ["app_rss_mib", "app_runtime_rss_mib", "agents_rss_mib", "total_rss_mib"]},
                "cpu_percent_one_core": cpu, "stable_process_groups": stable,
                "minimum_host_memory_available_percent": minimum_memory,
                "samples": samples,
                "boundary": "Idle real CLI frontends and owned descendants, no model prompts. Provider services outside the owned trees are excluded; this is not active agent-workload scaling."}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--output", default=".cache/m0-agent-benchmarks.json")
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error("--seconds must be positive")
    report = {"binary_sha256": hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest(), "results": [], "failures": []}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        output.write_text(json.dumps(report, indent=2) + "\n")
    for provider, count in [("codex", 1), ("claude", 1), ("mixed", 5), ("mixed", 10)]:
        print(f"Measuring {provider}: {count} agent CLI sessions", flush=True)
        try:
            result = run_case(provider, count, args.seconds)
        except Exception as error:
            report["failures"].append({"provider_mix": provider, "sessions": count, "error": str(error)})
            save()
            raise
        report["results"].append(result)
        save()
        print(json.dumps({key: result[key] for key in ["provider_mix", "sessions", "medians_mib", "cpu_percent_one_core", "stable_process_groups"]}), flush=True)


if __name__ == "__main__":
    main()
