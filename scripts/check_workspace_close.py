#!/usr/bin/env python3
"""Check supporting targets, view closure, and retained terminal ownership."""
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
    output = Path(args.output); output.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    with native_fixture(['--workspace-benchmark-count', '0', '--workspace-benchmark-close', '--workspace-benchmark-front'],
                        prefix='spookky-m1-close-', binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(90, 'Native workspace close failed')
        except Exception:
            evidence = fixture.preserve_evidence(output, ['app.log', 'continuity-failure.json', 'close-checks.json', 'close-focus-observation.json', 'foundation-dark-wide.png', 'foundation-light-narrow.png'])
            print('Close failure evidence: ' + str(evidence), flush=True)
            raise
        checks = json.loads((fixture.root / 'close-checks.json').read_text())
        focus_observation = json.loads((fixture.root / 'close-focus-observation.json').read_text())
        required = {'blank_home_draft', 'shell_from_landing_preserves_draft', 'primary_terminal_focus', 'native_terminal_input', 'cmd_t_browser_without_cli', 'cmd_t_opens_start_page_without_cli', 'new_browser_focuses_support_content',
                    'two_browser_targets_distinct', 'support_tab_shortcut_cycles_targets', 'support_host_retains_form_on_switch',
                    'full_width_and_collapse_preserve_form', 'panel_toggle_restores_selected_form', 'support_form_field_focused', 'support_close_keeps_primary_process',
                    'support_close_keeps_unsent_input', 'primary_close_retains_process_and_records', 'primary_cmd_w_closes_window_without_hiding_thread', 'landing_cmd_w_closes_window',
                    'reopen_same_process_without_prompt', 'reopen_retains_support_and_input',
                    'window_close_retains_restore_records', 'stop_cancel_preserves_owned_process',
                    'explicit_stop_ends_only_owned_primary', 'closed_shell_is_discoverable',
                    'reopen_support_shell_reuses_binding_and_input', 'cmd_n_restores_landing_draft', 'metadata_valid'}
        for image in ['foundation-dark-wide.png', 'foundation-light-narrow.png', 'supporting-new-tab.png']:
            import shutil
            shutil.copy2(fixture.root / image, Path(args.output).parent / image)
        if set(checks) != required:
            raise SystemExit('Close fixture is stale or its report is incomplete')
        database = fixture.root / 'metadata/workspace.sqlite'
        with sqlite3.connect(database) as connection:
            saved = json.loads(connection.execute('SELECT payload FROM workspace_snapshot').fetchone()[0])
        checks['retained_metadata_persisted'] = saved['version'] == 8 and len(saved['workspaces']) == 2 and sum(row.get('landingContext') == 'global' for row in saved['workspaces']) == 1
    result = {'binary_sha256': digest, 'checks': checks, 'focus_observation': focus_observation, 'failure_count': sum(not value for value in checks.values()),
              'boundary': 'Native shortcuts, AppKit keyboard event dispatch, and disposable shells. Physical keyboard confirmation remains separate.'}
    result['binary_changed_during_run'] = hashlib.sha256(args.binary.read_bytes()).hexdigest() != digest
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if result['failure_count'] or result['binary_changed_during_run']:
        raise SystemExit('Native workspace close failed')


if __name__ == '__main__':
    main()
