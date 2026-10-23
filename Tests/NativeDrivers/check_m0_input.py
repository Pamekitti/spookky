#!/usr/bin/env python3
"""Own disposable native input/folder fixtures and collect only their diagnostics."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import time

from native_fixture import NATIVE_BINARY, ROOT, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=["input", "folders"])
    parser.add_argument("--mode", choices=["direct", "persistent"], default="persistent")
    parser.add_argument("--output", required=True)
    parser.add_argument("--replay", action="store_true")
    parser.add_argument("--binary",type=Path,default=NATIVE_BINARY)
    args = parser.parse_args()
    documents = None
    try:
        if args.check == "folders":
            documents = Path(tempfile.mkdtemp(prefix="spookky-folder-probe-", dir=ROOT / ".cache"))
            arguments = ["--folder-probe", str(documents)]
        else:
            arguments = ["--input-fixture", "--interactive-checks"]
            if args.mode == "direct":
                arguments.append("--direct")
            if args.replay:
                arguments.append("--input-replay")

        def prepare(root):
            shutil.copyfile(ROOT / "scripts/terminal_input_fixture.py", root / "input-check.py")
            (root / "known.txt").write_text("SPOOKKY_KNOWN_FOLDER_CONTENT\n")
            python_check = "from pathlib import Path\nassert Path(__file__).with_name('known.txt').read_text() == 'SPOOKKY_KNOWN_FOLDER_CONTENT\\n'\nprint('SPOOKKY_PYTHON_READ_OK', flush=True)\n"
            (root / "read-check.py").write_text(python_check)
            if documents is not None:
                (documents / "known.txt").write_text("SPOOKKY_KNOWN_FOLDER_CONTENT\n")
                (documents / "read-check.py").write_text(python_check)

        with native_fixture(arguments, prefix="spookky-input-", prepare=prepare, binary=args.binary) as fixture:
            print(json.dumps({"pid": fixture.process.pid, "root": str(fixture.root), "check": args.check, "mode": args.mode}), flush=True)
            fixture.wait_ready(70, "Native fixture did not become ready.")
            if args.check == "input" and not args.replay:
                print("Verify the native fixture, then create the finish file in its printed root to collect and clean up.", flush=True)
                deadline = time.monotonic() + 1800
                while not (fixture.root / "finish").exists() and fixture.process.poll() is None:
                    if time.monotonic() > deadline:
                        raise RuntimeError("Input fixture exceeded its 30-minute verification window.")
                    time.sleep(0.2)
            result = {"check": args.check, "mode": args.mode,
                      "collected_at": datetime.now(timezone.utc).isoformat(),
                      "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                      "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                        for path in [*sorted((ROOT / "App").rglob("*.swift")), ROOT / "Sources/SpookkyLaunch/main.swift",
                                                     ROOT / "scripts/terminal_input_fixture.py", ROOT / "scripts/check_m0_input.py"]}}
            for name in ["input-bytes.json", "folder-probe.json"]:
                if (fixture.root / name).exists():
                    result[name] = json.loads((fixture.root / name).read_text())
            if (fixture.root / "input-events.jsonl").exists():
                result["input_events"] = [json.loads(line) for line in (fixture.root / "input-events.jsonl").read_text().splitlines()]
            result["samples"] = {path.name: path.read_text() for path in fixture.root.glob("sample-*.txt")}
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
            print("Collected " + str(output), flush=True)
            if args.check == "folders":
                rows = result.get("folder-probe.json", [])
                if len(rows) != 4 or not all(row.get("passed") for row in rows):
                    raise SystemExit("Folder probes failed or are incomplete; see the collected stages.")
            if args.replay:
                records = result.get("input-bytes.json", [])
                received = b"".join(bytes.fromhex(row["hex"]) for row in records)
                events = result.get("input_events", [])
                modifier_keys = [r for r in events if r["stage"] == "encoded_key" and r.get("keycode") in [56,60,59,62,58,61,55,54]]
                assertions = {
                    "committed_unicode": received.startswith(b"qq\x1b[200~") and "COMMITTED café ไทย 日本語".encode() in received,
                    "repeat_action": any(r["stage"] == "encoded_key" and r.get("action") == 2 for r in events),
                    "modifier_pairs": [r["action"] for r in modifier_keys] == [1,0] * 8,
                    "function_key_not_text": b"\x1bOP" in received and "\uf704".encode() not in received,
                    "option_as_alt": received.endswith(b"\x1bx"),
                    "no_automatic_enter": b"\r" not in received and b"\n" not in received,
                    "keyboard_sources": len({r.get("source_id") for r in events if r["stage"] == "selected_keyboard_source" and r.get("status") == 0}) >= 2,
                    "source_restored": any(r["stage"] == "restored_keyboard_source" and r.get("same_source") for r in events),
                    "source_notification": any(r["stage"] == "keyboard_source_notification" for r in events),
                    "ime_anchor_geometry": any(r["stage"] == "ime_anchor_geometry" and r.get("matches_cursor_bottom") and r.get("positive_cell_height") for r in events),
                    "empty_selection_range": any(r["stage"] == "ime_anchor_geometry" and r.get("empty_selection_range") for r in events),
                }
                result["assertions"] = assertions
                output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
                print(json.dumps(assertions), flush=True)
                if not all(assertions.values()):
                    raise SystemExit("Native replay failed; see the collected events and bytes.")
    finally:
        if documents is not None:
            shutil.rmtree(documents)


if __name__ == "__main__":
    main()
