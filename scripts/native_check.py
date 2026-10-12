#!/usr/bin/env python3
"""Run an isolated in-app terminal fixture check, never other applications."""
import argparse
import json
from pathlib import Path

from native_fixture import native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["self-test", "cycles"])
    parser.add_argument("--output", default=".cache/native-check.json")
    args = parser.parse_args()
    flag = "--benchmark-cycles" if args.mode == "cycles" else "--self-test"
    with native_fixture([flag], prefix="spookky-native-") as fixture:
        fixture.wait_ready(240, "Native check did not finish.")
        source = fixture.root / ("cycles.json" if args.mode == "cycles" else "self-test.json")
        result = json.loads(source.read_text())
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)
        if args.mode == "self-test" and not all(result.values()):
            raise SystemExit("Native terminal check contains a failed assertion.")


if __name__ == "__main__":
    main()
