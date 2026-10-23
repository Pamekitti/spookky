"""Run hosted native scenarios and compatibility drivers against private state."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import shutil
from gui_lock import gui_lock
from fixture_environment import git_environment
from check_execution import run, require_discovered
from binary_identity import code_hashes

ROOT = Path(__file__).resolve().parents[1]


def native_selector(case):
    qualified = case if "/" in case else "NativeScenarioTests/" + case
    return "-only-testing:SpookkyNativeTests/" + qualified


def validate_native_counts(counts):
    require_discovered(
        sum(counts[key] for key in ["passed", "failed", "skipped"]), "native"
    )
    if (
        counts["failed"]
        or counts["skipped"]
        or counts.get("infrastructure_failures", 0)
    ):
        raise RuntimeError("Native required cases did not pass: " + json.dumps(counts))


def native_tests(args):
    import uuid
    import hashlib
    from runtime_paths import tmux_path

    if not shutil.which("xcodebuild"):
        raise RuntimeError(
            "Native suites require full Xcode and a logged-in macOS desktop"
        )
    if not os.access(tmux_path(), os.X_OK):
        raise RuntimeError(
            "Native suites require the pinned runtime: python3 scripts/build_runtime.py"
        )
    if not (ROOT / ".cache/dependencies/ghostty/macos/GhosttyKit.xcframework").exists():
        raise RuntimeError(
            "Native suites require the pinned terminal library: python3 scripts/build_ghostty.py"
        )
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild",
        "-quiet",
        "-jobs",
        "2",
        "-project",
        "Spookky.xcodeproj",
        "-scheme",
        "SpookkyHarness",
        "-configuration",
        args.configuration.title(),
        "-derivedDataPath",
        "DerivedData",
        "ARCHS=arm64",
        "SPOOKKY_INSTANCE_ID=" + hashlib.sha256(str(ROOT).encode()).hexdigest()[:16],
        "OTHER_SWIFT_FLAGS=$(inherited) -j2",
        "-parallel-testing-enabled",
        "NO",
        "-test-timeouts-enabled",
        "YES",
        "-default-test-execution-time-allowance",
        "120",
        "-maximum-test-execution-time-allowance",
        "180",
    ]
    run(command + ["build-for-testing"], evidence=output / "native-build.log")
    binary = (
        ROOT
        / "DerivedData/Build/Products"
        / args.configuration.title()
        / "SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
    )
    identity = code_hashes(binary)
    all_cases = []
    for source in sorted((ROOT / "Tests/SpookkyNativeTests").glob("*.swift")):
        owner = re.search(r"class (\w+): XCTestCase", source.read_text())
        if owner:
            all_cases.extend(
                owner[1] + "/" + method
                for method in re.findall(r"func (test\w+)\(", source.read_text())
            )
    cases = (
        [args.case]
        if args.case
        else (
            ["NativeScenarioTests/testSmoke"]
            if args.group == "native-smoke"
            else all_cases
        )
    )
    cases = [case if "/" in case else "NativeScenarioTests/" + case for case in cases]
    if any(case not in all_cases for case in cases):
        raise RuntimeError(
            "No tests discovered for selected native case: " + str(args.case)
        )
    require_discovered(len(cases), "native selection")
    counts = dict(
        passed=0,
        failed=0,
        skipped=0,
        excluded=len(all_cases) - len(cases),
        infrastructure_failures=0,
    )
    result_paths = []
    # Ghostty and AppKit application services have process lifetime. Each native scenario
    # gets a fresh hosted process, matching the normal application's ownership model.
    for case in cases:
        with tempfile.TemporaryDirectory(
            prefix="spookky-m1-xctest-", dir="/tmp"
        ) as private:
            environment = dict(
                git_environment(os.environ),
                SPOOKKY_SOURCE_ROOT=str(ROOT),
                SPOOKKY_TEST_EVIDENCE=str(output),
                SPOOKKY_M1_ROOT=private,
                SPOOKKY_M1_DATA=private + "/metadata",
                SPOOKKY_M0_ROOT=private,
            )
            environment.update(
                {
                    "TEST_RUNNER_" + key: value
                    for key, value in environment.items()
                    if key.startswith(("SPOOKKY_", "GIT_"))
                }
            )
            result = output / (
                case.replace("/", "-") + "-" + uuid.uuid4().hex + ".xcresult"
            )
            result_paths.append(str(result))
            with gui_lock():
                try:
                    command_failed = False
                    try:
                        run(
                            command
                            + [
                                native_selector(case),
                                "-resultBundlePath",
                                str(result),
                                "test-without-building",
                            ],
                            env=environment,
                            evidence=result.with_suffix(".log"),
                        )
                    except subprocess.CalledProcessError:
                        command_failed = True
                    data = run(
                        [
                            "xcrun",
                            "xcresulttool",
                            "get",
                            "test-results",
                            "summary",
                            "--path",
                            str(result),
                        ],
                        capture=True,
                    )
                    summary = json.loads(data)
                    require_discovered(summary.get("totalTestCount", 0), case)
                    if (
                        command_failed or summary.get("result") != "Passed"
                    ) and not summary.get("failedTests", 0):
                        counts["infrastructure_failures"] += 1
                    counts["passed"] += summary.get("passedTests", 0)
                    counts["failed"] += summary.get("failedTests", 0)
                    counts["skipped"] += summary.get("skippedTests", 0)
                finally:
                    for socket in Path(private).rglob("socket"):
                        subprocess.run(
                            [tmux_path(), "-S", str(socket), "kill-server"],
                            capture_output=True,
                        )
    import hashlib

    binary = (
        ROOT
        / "DerivedData/Build/Products"
        / args.configuration.title()
        / "SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
    )
    identity_matches = code_hashes(binary) == identity
    if not identity_matches:
        counts["infrastructure_failures"] += 1
    report = dict(
        binary_hashes=identity,
        binary_identity_matches=identity_matches,
        suite=args.group,
        passed=not (
            counts["failed"] or counts["skipped"] or counts["infrastructure_failures"]
        ),
        counts=counts,
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        evidence=result_paths,
        resources={},
    )
    (output / "native-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    validate_native_counts(counts)
    return counts


def legacy_native(name, arguments=None):
    import runpy
    from fixture_results import validate_checks

    driver = ROOT / "Tests/NativeDrivers" / name
    if not driver.is_file():
        raise RuntimeError("Unknown native suite: " + name)
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    previous_arguments = sys.argv
    try:
        sys.argv = [str(driver), *arguments]
        runpy.run_path(str(driver), run_name="__main__")
    finally:
        sys.argv = previous_arguments
    if "--output" not in arguments:
        return
    destination = Path(arguments[arguments.index("--output") + 1])
    if not destination.is_file() or destination.suffix != ".json":
        return
    data = json.loads(destination.read_text())
    checks = data.get("checks")
    if name == "check_m0_input.py":
        if "assertions" in data:
            checks = data["assertions"]
            required = json.loads(
                (ROOT / "Tests/Inventory/native-assertions.json").read_text()
            )["input-replay.json"]
        else:
            rows = data.get("folder-probe.json", [])
            checks = {
                "folder_probe_" + str(index): row.get("passed")
                for index, row in enumerate(rows)
            }
            required = {"folder_probe_" + str(index) for index in range(4)}
        validate_checks(checks, required)
        data.update(
            checks=checks,
            suite=name.removesuffix(".py"),
            passed=True,
            counts=dict(passed=len(checks), failed=0, skipped=0, excluded=0),
        )
    if checks is not None:
        contracts = json.loads(
            (ROOT / "Tests/Inventory/native-assertions.json").read_text()
        )
        report_name = {
            "check_new_session.py": "composer-checks.json",
            "check_prompt_images.py": "prompt-image-checks.json",
            "check_conversation_identity.py": "identity-checks.json",
            "check_workspace_close.py": "close-checks.json",
            "check_sidebar.py": "sidebar-checks.json",
            "check_sidebar_reference.py": "sidebar-reference-checks.json",
            "check_session_history.py": "history-checks.json",
            "check_surface_races.py": "surface-races.json",
            "check_terminal_selection.py": "selection-checks.json",
            "check_project_association.py": "project-association-checks.json",
            "check_sidebar_restart.py": "sidebar-restart.json",
            "check_m0_recovery.py": "recovery.json",
            "check_workspace_recovery.py": "workspace-recovery.json",
            "native_check.py": "self-test.json",
        }.get(name)
        validate_checks(checks, contracts[report_name] if report_name else set(checks))
        data.update(
            suite=name.removesuffix(".py"),
            passed=True,
            counts=dict(passed=len(checks), failed=0, skipped=0, excluded=0),
        )
    if checks is not None:
        identity_ids = {"binary_unchanged", "verified_binary_unchanged"}
        data["binary_identity_checks"] = {
            key: value for key, value in checks.items() if key in identity_ids
        }
        data["behavioral_checks"] = {
            key: value for key, value in checks.items() if key not in identity_ids
        }
        data["counts"]["passed"] = len(data["behavioral_checks"])
    if "binarySHA256" in data:
        data["binary_sha256"] = data["binarySHA256"]
    if "--binary" in arguments:
        data["binary_hashes"] = code_hashes(arguments[arguments.index("--binary") + 1])
    data.setdefault("resources", {})
    data.setdefault(
        "evidence",
        data.get("screenshots", [data["screenshot"]] if "screenshot" in data else []),
    )
    destination.write_text(json.dumps(data, indent=2) + "\n")


def run_native(args):
    results = {}
    results[args.group] = native_tests(args)
    # Recovery needs an independently killable app process, outside the hosted test runner.
    recovery = Path(args.output).resolve() / "recovery.json"
    recovery.parent.mkdir(parents=True, exist_ok=True)
    legacy_native(
        "check_workspace_recovery.py",
        [
            "--output",
            str(recovery),
            "--binary",
            str(
                ROOT
                / "DerivedData/Build/Products"
                / args.configuration.title()
                / "SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
            ),
        ],
    )
    from fixture_results import validate_checks

    checks = json.loads(recovery.read_text())["checks"]
    contracts = json.loads(
        (ROOT / "Tests/Inventory/native-assertions.json").read_text()
    )
    validate_checks(checks, contracts["workspace-recovery.json"])
    results["native-recovery"] = dict(
        passed=len(checks), failed=0, skipped=0, excluded=0
    )
    if args.group == "native" and not args.case:
        binary = (
            ROOT
            / "DerivedData/Build/Products"
            / args.configuration.title()
            / "SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
        )
        extras = [
            ("check_m0_recovery.py", ["--binary", str(binary)]),
            ("check_supporting_previews.py", ["--binary", str(binary)]),
            ("check_sidebar_restart.py", ["--binary", str(binary)]),
            ("native_check.py", ["self-test", "--binary", str(binary)]),
            ("check_m0_input.py", ["folders", "--binary", str(binary)]),
            (
                "check_m0_input.py",
                ["input", "--mode", "direct", "--replay", "--binary", str(binary)],
            ),
            (
                "check_m0_input.py",
                ["input", "--mode", "persistent", "--replay", "--binary", str(binary)],
            ),
        ]
        for index, (driver, arguments) in enumerate(extras):
            destination = Path(args.output) / (
                "browser"
                if driver == "check_supporting_previews.py"
                else Path(driver).stem + "-" + str(index) + ".json"
            )
            legacy_native(driver, arguments + ["--output", str(destination)])
    return results
