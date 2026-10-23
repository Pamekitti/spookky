#!/usr/bin/env python3
"""Run the selected checks with existing test tools and explicit discovery."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from gui_lock import gui_lock
from fixture_environment import git_environment, isolated_git
from check_execution import run, require_discovered
from native_runner import (
    legacy_native,
    run_native,
    native_selector,
    validate_native_counts,
)

ROOT = Path(__file__).resolve().parents[1]
GROUPS = (
    "source",
    "unit",
    "integration",
    "native-smoke",
    "native",
    "website",
    "providers",
    "performance",
    "python",
)


def python_tests():
    sys.path.insert(0, str(ROOT / "scripts"))
    suite = unittest.defaultTestLoader.discover(
        str(ROOT / "Tests/Python"), pattern="test_*.py"
    )
    require_discovered(suite.countTestCases(), "python")
    with isolated_git():
        result = unittest.TextTestRunner(verbosity=1).run(suite)
    if not result.wasSuccessful():
        raise RuntimeError("Python tooling checks failed")
    return dict(
        passed=result.testsRun - len(result.skipped),
        failed=0,
        skipped=len(result.skipped),
        excluded=0,
    )


def swift_tests(group, configuration):
    env = git_environment(os.environ)
    if group == "performance":
        env["SPOOKKY_PERFORMANCE"] = "1"
    if group in ["integration", "providers"]:
        run(
            [
                "swift",
                "build",
                "-c",
                configuration,
                "--jobs",
                "2",
                "--product",
                "spookky-launch",
            ],
            env=env,
        )
    name = {
        "unit": "SpookkyUnitTests",
        "integration": "SpookkyIntegrationTests",
        "providers": "SpookkyProviderTests",
        "performance": "SpookkyPerformanceTests",
    }[group]
    output = run(
        ["swift", "test", "-c", configuration, "--jobs", "2", "--filter", name],
        env=env,
        capture=True,
    )
    counts = re.findall(
        r"Executed (\d+) tests?(?:, with (\d+) tests? skipped)?(?: and|, with) (\d+) failures",
        output,
    )
    if not counts:
        raise RuntimeError("No XCTest summary for " + group)
    total, skipped, failed = max((int(a), int(b or 0), int(c)) for a, b, c in counts)
    require_discovered(total, group)
    return dict(
        passed=total - skipped - failed, failed=failed, skipped=skipped, excluded=0
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", nargs="?", choices=GROUPS)
    parser.add_argument(
        "--case", help="One hosted XCTest method to diagnose a failed native scenario"
    )
    parser.add_argument(
        "--workload-seconds",
        type=int,
        default=60,
        help="Bounded performance continuity duration; overnight runs use the dedicated benchmark script",
    )
    parser.add_argument(
        "--suite", help="Compatibility driver name, such as check_new_session.py"
    )
    parser.add_argument(
        "--configuration", choices=["debug", "release"], default="debug"
    )
    parser.add_argument("--output", default=".cache/tests")
    args, extra = parser.parse_known_args()
    if args.case and args.group not in ["native", "native-smoke"]:
        parser.error("--case selects a hosted native XCTest case")
    if args.case and args.suite:
        parser.error("Select --case or --suite, not both")
    if args.suite:
        if args.group != "native":
            parser.error("--suite requires native")
        destination = Path(args.output)
        if (
            destination.suffix != ".json"
            and args.suite != "check_supporting_previews.py"
        ):
            destination = destination / (Path(args.suite).stem + ".json")
        binary_drivers = {
            path.name
            for path in (ROOT / "Tests/NativeDrivers").glob("*.py")
            if 'add_argument("--binary"' in path.read_text()
            or "add_argument('--binary'" in path.read_text()
        }
        if args.suite in binary_drivers and "--binary" not in extra:
            extra += [
                "--binary",
                str(
                    ROOT
                    / "DerivedData/Build/Products"
                    / args.configuration.title()
                    / "SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
                ),
            ]
        legacy_native(args.suite, extra + ["--output", str(destination)])
        return
    if extra:
        parser.error("Unrecognized arguments: " + " ".join(extra))
    groups = [args.group] if args.group else ["source", "unit", "integration"]
    results = {}
    for group in groups:
        if group == "source":
            run([sys.executable, "scripts/check_repo.py"])
            results["python"] = python_tests()
        elif group == "python":
            results[group] = python_tests()
        elif group in ["unit", "integration", "providers"]:
            results[group] = swift_tests(group, args.configuration)
        elif group.startswith("native"):
            results.update(run_native(args))
        elif group == "website":
            output = Path(args.output).resolve() / "website.json"
            output.parent.mkdir(parents=True, exist_ok=True)
            run(
                ["npm", "test", "--prefix", "website", "--", "--reporter=json"],
                env=dict(os.environ, PLAYWRIGHT_JSON_OUTPUT_FILE=str(output)),
            )
            stats = json.loads(output.read_text())["stats"]
            require_discovered(
                sum(
                    stats.get(key, 0)
                    for key in ["expected", "unexpected", "skipped", "flaky"]
                ),
                "website",
            )
            results[group] = dict(
                passed=stats["expected"] + stats["flaky"],
                failed=stats["unexpected"],
                skipped=stats["skipped"],
                excluded=0,
            )
        elif group == "performance":
            results["performance-cases"] = swift_tests(
                "performance", args.configuration
            )
            run(
                [
                    sys.executable,
                    "scripts/benchmark_m1.py",
                    "--seconds",
                    "60",
                    "--output",
                    str(Path(args.output) / "performance.json"),
                ]
            )
            run(
                [
                    sys.executable,
                    "scripts/benchmark_m3.py",
                    "--mode",
                    "diff",
                    "--output",
                    str(Path(args.output) / "diff.json"),
                ]
            )
            run(
                [
                    sys.executable,
                    "scripts/benchmark_m4.py",
                    "--seconds",
                    str(args.workload_seconds),
                    "--background",
                    "--skip-timing",
                    "--output",
                    str(Path(args.output) / "lifecycle.json"),
                ]
            )
    excluded = (
        sum(
            len(re.findall(r"func test\w+\(", path.read_text()))
            for path in (ROOT / "Tests/SpookkyProviderTests").rglob("*.swift")
        )
        if args.group is None
        else 0
    )
    print(
        json.dumps(
            dict(
                suites=results,
                excluded_provider_cases=excluded,
                excluded_performance_cases=1 if args.group is None else 0,
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    try:
        (ROOT / ".cache").mkdir(exist_ok=True)
        with gui_lock(path=ROOT / ".cache/build.lock"):
            main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
