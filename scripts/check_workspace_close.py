#!/usr/bin/env python3
"""Check first launch, shortcut routing, and final-tab closure in an owned app."""
import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
import time
from pathlib import Path
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    with native_fixture(['--workspace-benchmark-count', '0', '--workspace-benchmark-close', '--workspace-benchmark-front'],
                        prefix='spookky-m1-close-', binary=args.binary, workspace=True) as fixture:
        fixture.wait_ready(90, 'Native workspace close failed')
        checks = json.loads((fixture.root / 'close-checks.json').read_text())
        required = {'first_launch_blank_home', 'final_blank_closes_window', 'cmd_t_reopens_one_terminal',
                    'native_shell_input', 'cmd_t_running_adds_blank', 'close_blank_retains_shell',
                    'escape_keeps_shell_and_focus', 'enter_closes_final_without_replacement',
                    'reopen_shows_home_landing', 'cmd_n_reopens_blank', 'empty_state_valid'}
        if set(checks) != required:
            raise SystemExit('Close fixture is stale or its report is incomplete')
        fixture.process.terminate()
        fixture.process.wait(timeout=5)
        database = fixture.root / 'metadata/workspace.sqlite'
        with sqlite3.connect(database) as connection:
            saved = json.loads(connection.execute('SELECT payload FROM workspace_snapshot').fetchone()[0])
        if saved['workspaces']:
            raise SystemExit('Final-tab closure did not persist the empty state')
        environment = os.environ.copy()
        environment.update(SPOOKKY_M1_ROOT=str(fixture.root), SPOOKKY_M1_DATA=str(fixture.root / 'metadata'))
        with (fixture.root / 'reopen.log').open('w') as log:
            fixture.process = subprocess.Popen([str(args.binary), '--workspace-benchmark-restoring'], env=environment,
                                               stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            restored = None
            while time.monotonic() < deadline:
                if fixture.process.poll() is not None:
                    raise SystemExit('Saved-empty startup failed')
                with sqlite3.connect(database) as connection:
                    restored = json.loads(connection.execute('SELECT payload FROM workspace_snapshot').fetchone()[0])
                if len(restored['workspaces']) == 1:
                    break
                time.sleep(0.02)
        workspaces = restored['workspaces'] if restored else []
        tabs = workspaces[0]['tabs'] if len(workspaces) == 1 else []
        checks['saved_empty_startup_shows_landing'] = len(tabs) == 1 and tabs[0]['status'] == 'draft' and not tabs[0].get('binding')
    result = {'binary_sha256': digest, 'checks': checks, 'failure_count': sum(not value for value in checks.values()),
              'boundary': 'Native shortcuts, AppKit keyboard event dispatch, and disposable shells. Physical keyboard confirmation remains separate.'}
    result['binary_changed_during_run'] = hashlib.sha256(args.binary.read_bytes()).hexdigest() != digest
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if result['failure_count'] or result['binary_changed_during_run']:
        raise SystemExit('Native workspace close failed')


if __name__ == '__main__':
    main()
