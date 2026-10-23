#!/usr/bin/env python3
"""Crash/reopen the shared workspace lifecycle with one owned shell and an unsent draft."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess

from benchmark_m1 import request_cpu
from fixture_environment import git_environment
from fixture_results import report
from native_fixture import NATIVE_BINARY, TMUX, native_fixture

REQUIRED = {
    "runtime_survives_crash",
    "same_shell_after_reopen",
    "one_session",
    "one_attached_client",
    "terminal_input_retained",
    "composer_draft_retained",
    "draft_not_replayed",
    "same_workspaces_and_selection",
    "fresh_app_receipt",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=NATIVE_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    flags = [
        "--workspace-measure",
        "--workspace-benchmark-count",
        "1",
        "--workspace-benchmark-conversations",
        "--workspace-benchmark-recovery",
    ]
    with native_fixture(
        flags, prefix="spookky-m1-recovery-", binary=args.binary, workspace=True
    ) as fixture:
        fixture.wait_ready(60, "Workspace recovery seed did not become ready")

        def tmux(*arguments):
            return subprocess.check_output(
                [TMUX, "-S", str(fixture.root / "socket"), *arguments], text=True
            ).strip()

        def snapshot():
            with sqlite3.connect(
                fixture.root / "metadata/workspace.sqlite"
            ) as database:
                return json.loads(
                    database.execute(
                        "SELECT payload FROM workspace_snapshot WHERE id=1"
                    ).fetchone()[0]
                )

        def panes():
            return tmux(
                "list-panes", "-a", "-F", "#{session_name}|#{pane_pid}"
            ).splitlines()

        before = snapshot()
        before_panes = panes()
        draft = next(
            tab
            for workspace in before["workspaces"]
            for tab in workspace["tabs"]
            if tab["draft"]["prompt"] == "SPOOKKY_UNSENT_COMPOSER_RECOVERY"
        )
        marker = "SPOOKKY_WORKSPACE_TERMINAL_UNSENT"
        pane = tmux("list-panes", "-a", "-F", "#{pane_id}")
        tmux("send-keys", "-t", pane, "-l", marker)
        fixture.wait_for(
            lambda: marker in tmux("capture-pane", "-t", pane, "-p"),
            5,
            "Terminal input did not reach the owned shell",
        )
        fixture.process.kill()
        fixture.process.wait(timeout=5)
        survived = panes() == before_panes
        environment = dict(
            git_environment(os.environ),
            SPOOKKY_M0_ROOT=str(fixture.root),
            SPOOKKY_M1_ROOT=str(fixture.root),
            SPOOKKY_M1_DATA=str(fixture.root / "metadata"),
        )
        with (fixture.root / "reopen.log").open("w") as log:
            fixture.process = subprocess.Popen(
                [
                    str(args.binary),
                    "--workspace-measure",
                    "--workspace-benchmark-restoring",
                ],
                env=environment,
                stdout=log,
                stderr=log,
            )
            sample = {}

            def attached():
                nonlocal sample
                sample = request_cpu(fixture)
                return (
                    sample["pid"] == fixture.process.pid
                    and tmux("list-clients", "-F", "#{client_pid}").count("\n") == 0
                    and bool(tmux("list-clients", "-F", "#{client_pid}"))
                )

            fixture.wait_for(
                attached,
                30,
                "The restored workspace did not attach to its surviving shell",
            )
            after = snapshot()
            restored = next(
                tab
                for workspace in after["workspaces"]
                for tab in workspace["tabs"]
                if tab["id"] == draft["id"]
            )
            checks = dict(
                runtime_survives_crash=survived,
                same_shell_after_reopen=panes() == before_panes,
                one_session=len(
                    tmux("list-sessions", "-F", "#{session_name}").splitlines()
                )
                == 1,
                one_attached_client=len(
                    tmux("list-clients", "-F", "#{client_pid}").splitlines()
                )
                == 1,
                terminal_input_retained=marker
                in tmux("capture-pane", "-t", pane, "-p"),
                composer_draft_retained=restored["draft"]["prompt"]
                == draft["draft"]["prompt"],
                draft_not_replayed=restored["status"] == "draft"
                and restored.get("launch") is None
                and restored.get("binding") is None,
                same_workspaces_and_selection=[w["id"] for w in before["workspaces"]]
                == [w["id"] for w in after["workspaces"]]
                and before["selectedWorkspaceID"] == after["selectedWorkspaceID"],
                fresh_app_receipt=sample["pid"] == fixture.process.pid,
            )
            data = report(
                "workspace-recovery",
                checks,
                REQUIRED,
                binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(data, indent=2) + "\n")
            print(json.dumps(data), flush=True)


if __name__ == "__main__":
    main()
