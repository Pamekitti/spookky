#!/usr/bin/env python3
"""Crash and reopen only an isolated native fixture, preserving its private session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from native_fixture import NATIVE_BINARY, TMUX, NativeFixture, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=".cache/m0-recovery.json")
    args = parser.parse_args()
    with native_fixture(["--benchmark-count", "1"], prefix="spookky-recovery-") as fixture:
        fixture.wait_ready(60, "Recovery fixture failed to start.")
        def tmux(*arguments):
            return subprocess.check_output([TMUX, "-S", str(fixture.root / "socket"), *arguments], text=True).strip()
        bindings = [json.loads(path.read_text()) for path in fixture.root.glob("*.json") if len(path.stem) == 36]
        if len(bindings) != 1:
            raise RuntimeError("Expected exactly one owned fixture binding.")
        binding = bindings[0]
        target = "=" + binding["name"]
        def observation():
            return tmux("list-panes", "-t", target, "-F", "#{SPOOKKY_M0_TOKEN}\t#{pane_pid}\t#{session_attached}\t#{pane_id}").split("\t")
        identity = observation()[0]
        if identity != binding["token"]:
            raise RuntimeError("Fixture ownership token did not match.")
        before_pid = observation()[1]
        pane = observation()[3]
        marker = "SPOOKKY_UNSENT_RECOVERY_DRAFT"
        tmux("send-keys", "-t", pane, "-l", marker)
        time.sleep(0.2)
        before_screen = tmux("capture-pane", "-t", pane, "-p")
        if marker not in before_screen:
            raise RuntimeError("Recovery draft did not reach the disposable cat fixture.")
        fixture.process.kill()
        fixture.process.wait(timeout=5)
        survived = observation()[1] == before_pid
        (fixture.root / "ready.json").unlink()
        environment = os.environ.copy()
        environment["SPOOKKY_M0_ROOT"] = str(fixture.root)
        with (fixture.root / "reopen.log").open("w") as log:
            reopened = subprocess.Popen([str(NATIVE_BINARY), "--terminal-harness", "--benchmark-count", "0"], env=environment, stdout=log, stderr=log)
            try:
                NativeFixture(fixture.root, reopened).wait_ready(60, "Reopened app did not restore.")
                ready = json.loads((fixture.root / "ready.json").read_text())
                after_screen = tmux("capture-pane", "-t", pane, "-p")
                checks = {"runtime_survived_app_crash": survived,
                          "same_process_after_reopen": observation()[1] == before_pid,
                          "unsent_draft_preserved": marker in after_screen,
                          "history_preserved": "Spookky fixture 04999" in after_screen,
                          "one_session": len(tmux("list-sessions", "-F", "#{session_name}").splitlines()) == 1,
                          "one_attached_client": observation()[2] == "1",
                          "fresh_ready_receipt": ready["pid"] == reopened.pid}
                result = {"binary_sha256": hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest(),
                          "checks": checks,
                          "boundary": "SIGKILL of the owned app, then new process using its private root. Draft injected as literal data into owned cat; no Enter. Excludes machine sleep/reboot and provider resume."}
                output = Path(args.output)
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(result, indent=2) + "\n")
                print(json.dumps(checks), flush=True)
                if not all(checks.values()):
                    raise SystemExit("Recovery contains a failed assertion.")
            finally:
                reopened.terminate()
                try:
                    reopened.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    reopened.kill()
                    reopened.wait()


if __name__ == "__main__":
    main()
