#!/usr/bin/env python3
"""Observe native input reaching completed rendered pixels, without screen capture."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from benchmark_m0 import summarize
from native_fixture import NATIVE_BINARY, ROOT, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=".cache/m0-rendered-input.json")
    parser.add_argument("--case", dest="named_case", choices=["all", "direct-idle", "direct-loaded", "persistent-idle", "persistent-loaded"], default="all")
    args = parser.parse_args()
    report = {"binary_sha256": hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest(), "results": []}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    for mode in ["direct", "persistent"]:
        for loaded in [False, True]:
            if args.named_case != "all" and args.named_case != mode + ("-loaded" if loaded else "-idle"):
                continue
            flags = ["--benchmark-render"] + (["--direct"] if mode == "direct" else []) + (["--output-load"] if loaded else [])
            def prepare(root):
                shutil.copyfile(ROOT / "scripts/render_input_fixture.py", root / "render-input.py")
            with native_fixture(flags, prefix="spookky-render-", prepare=prepare) as fixture:
                fixture.wait_ready(90, "Rendered-input fixture failed.")
                result = json.loads((fixture.root / "rendered-input.json").read_text())
            rows = result["samples"]
            result.update(summarize([row["milliseconds"] for row in rows]))
            result["mode"] = mode
            result["failure_count"] = sum(not row["matched"] for row in rows)
            report["results"].append(result)
            output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({key: result[key] for key in ["mode", "output_lines_per_second", "sample_count", "median_ms", "p95_ms", "failure_count"]}), flush=True)
            if result["failure_count"] or len(rows) != 100:
                raise SystemExit("Rendered-input check failed or incomplete; inspect its report.")


if __name__ == "__main__":
    main()
