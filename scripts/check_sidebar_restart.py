#!/usr/bin/env python3
"""Verify unread completion survives an app restart without restarting its shells."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time
from native_fixture import NATIVE_BINARY, TMUX, native_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    with native_fixture(['--workspace-benchmark-count', '3', '--workspace-benchmark-activity'],
                        prefix='spookky-m1-sidebar-restart-', binary=args.binary, workspace=True) as fixture:
        fixture.wait_ready(60, 'Activity restart fixture failed')

        def tabs():
            with sqlite3.connect(fixture.root / 'metadata/workspace.sqlite') as database:
                payload = database.execute('SELECT payload FROM workspace_snapshot WHERE id = 1').fetchone()[0]
            return {tab['id']: tab for workspace in json.loads(payload)['workspaces'] for tab in workspace['tabs']}

        def panes():
            return subprocess.check_output([TMUX, '-S', str(fixture.root / 'socket'), 'list-panes', '-a',
                                            '-F', '#{session_name}|#{pane_pid}'], text=True).splitlines()

        before = tabs()
        completed = next(tab for tab in before.values() if tab.get('activity', {}).get('state') == 'finished')
        completion = completed['activity']['completionID']
        before_panes = panes()
        fixture.process.terminate()
        fixture.process.wait(timeout=5)
        environment = dict(os.environ, SPOOKKY_M1_ROOT=str(fixture.root),
                           SPOOKKY_M1_DATA=str(fixture.root / 'metadata'), SPOOKKY_M0_ROOT=str(fixture.root))
        with (fixture.root / 'restart.log').open('w') as log:
            fixture.process = subprocess.Popen([str(args.binary), '--workspace-benchmark-restoring'], env=environment,
                                               stdout=log, stderr=log)
            deadline = time.monotonic() + 15
            while True:
                restored = tabs().get(completed['id'], {}).get('activity', {})
                if restored.get('state') == 'unknown':
                    break
                if fixture.process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Restart did not persist restored activity: ' + (fixture.root / 'restart.log').read_text()[-1000:])
                time.sleep(0.05)
            checks = dict(completion_identity_survives=restored.get('completionID') == completion,
                          completion_remains_unseen=restored.get('seenCompletionID') != completion,
                          lost_tracking_stays_unknown=restored.get('state') == 'unknown' and not restored.get('attached', False),
                          shell_processes_survive=sorted(panes()) == sorted(before_panes),
                          binary_unchanged=hashlib.sha256(args.binary.read_bytes()).hexdigest() == digest)
    report = dict(passed=all(checks.values()), binarySHA256=digest, checks=checks,
                  boundary='Real background native app restart and SQLite reload, with synthetic provider completion and three private shells. Foreground viewport acknowledgment is checked separately.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    if not report['passed']:
        raise SystemExit('Sidebar restart checks failed')


if __name__ == '__main__':
    main()
