#!/usr/bin/env python3
"""Run an isolated in-app terminal fixture check, never other applications."""
import argparse
import json
from pathlib import Path

from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["self-test", "cycles"])
    parser.add_argument("--output", default=".cache/native-check.json")
    parser.add_argument("--binary",type=Path,default=NATIVE_BINARY)
    args = parser.parse_args()
    flag = "--benchmark-cycles" if args.mode == "cycles" else "--self-test"
    with native_fixture([flag], prefix="spookky-native-", binary=args.binary) as fixture:
        fixture.wait_ready(240, "Native check did not finish.")
        source = fixture.root / ("cycles.json" if args.mode == "cycles" else "self-test.json")
        result = fixture.read_checks(source.name) if args.mode=="self-test" else json.loads(source.read_text())
        if args.mode == 'self-test':
            from fixture_results import report
            import hashlib
            result = dict(result, **report('terminal-self-test',result,fixture.read_checks('self-test.json'),binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest()))
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)
        if args.mode == "self-test" and result["passed"] is not True:
            raise SystemExit("Native terminal check contains a failed assertion.")


if __name__ == "__main__":
    main()
