#!/usr/bin/env python3
"""Exercise first-prompt clipboard images through the native responder chain."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=NATIVE_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with native_fixture(["--workspace-benchmark-count", "0", "--workspace-benchmark-prompt-images", "--workspace-benchmark-front"],
                        prefix="spookky-m1-prompt-images-", binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(120, "Native image paste check failed")
        except Exception:
            for name in ["app.log", "prompt-image-checks.json", "prompt-image-resources.json", "prompt-images.png"]:
                source = fixture.root / name
                if source.exists():
                    shutil.copy2(source, args.output.with_name(args.output.stem + "-failure-" + name))
            raise
        checks = fixture.read_checks('prompt-image-checks.json')
        resources = json.loads((fixture.root / "prompt-image-resources.json").read_text())
        rss = subprocess.check_output(["ps", "-o", "rss=", "-p", str(fixture.process.pid)], text=True).strip()
        resources["app_rss_mib_at_ready"] = int(rss) / 1024
        screenshot = args.output.with_suffix(".png")
        shutil.copy2(fixture.root / "prompt-images.png", screenshot)
        report = {"checks": checks, "resources": resources, "screenshot": str(screenshot),
                  "boundary": "Native responder-chain paste using a private pasteboard. No model requests or physical keyboard input."}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not checks or not all(checks.values()):
            raise SystemExit("Native image paste check failed")


if __name__ == "__main__":
    main()
