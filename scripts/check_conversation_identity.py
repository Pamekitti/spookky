#!/usr/bin/env python3
"""Verify primary provider identity and title refresh with disposable shell metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=NATIVE_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--background", action="store_true", help="Keep the fixture behind user windows.")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    arguments = ["--workspace-benchmark-count", "0", "--workspace-benchmark-identity"]
    if not args.background:
        arguments.append("--workspace-benchmark-front")
    with native_fixture(arguments,
                        prefix="spookky-m1-identity-", binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(60, "Native identity check failed")
        except Exception:
            evidence = fixture.preserve_evidence(args.output, ['app.log', 'identity-checks.json', 'continuity-failure.json'])
            print('Identity failure evidence: ' + str(evidence), flush=True)
            raise
        checks = json.loads((fixture.root / "identity-checks.json").read_text())
        ready = json.loads((fixture.root / "ready.json").read_text())
        checks["exact_disposable_runtime_count"] = ready["session_count"] == 2
        screenshots = []
        for source in sorted(fixture.root.glob("identity-*.png")):
            destination = args.output.with_name(source.name)
            shutil.copyfile(source, destination)
            screenshots.append(str(destination))
        debug_library = args.binary.with_name("Spookky.debug.dylib")
        report = {
            "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
            "debug_library_sha256": hashlib.sha256(debug_library.read_bytes()).hexdigest() if debug_library.exists() else None,
            "background_fixture": args.background,
            "runtime_session_count": ready["session_count"],
            "checks": checks,
            "screenshots": screenshots,
            "boundary": "Native AppKit controls, installed browser host and two real disposable shells. Provider titles and identity switches are fixtures. Browser interaction has its own fixture. No model requests. Spoken VoiceOver and physical keyboard use remain separate.",
        }
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not checks or not all(checks.values()):
            raise SystemExit("Native identity check failed")


if __name__ == "__main__":
    main()
