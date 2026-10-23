#!/usr/bin/env python3
"""Inspect installed resume interfaces without sending prompts or changing config."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

from native_fixture import TMUX, NATIVE_BINARY


def help_result(executable, arguments):
    result = subprocess.run([executable, *arguments], capture_output=True, text=True, timeout=15)
    return result.returncode, (result.stdout + result.stderr)[:65536]


def missing_history(executable, arguments, root):
    socket = root / 'socket'
    request = root / 'request.json'
    operation = str(uuid.uuid4())
    receipt = root / 'exec.json'
    spec = dict(operationID=operation, tool='shell', executable=executable, arguments=arguments,
                directory=str(root / 'checkout'), environment={'PATH': os.environ.get('PATH', '/usr/bin:/bin')})
    request.write_text(json.dumps(dict(spec=spec, resultPath=str(receipt))))
    request.chmod(0o600)
    helper = NATIVE_BINARY.parent / 'spookky-launch'
    config = root / 'tmux.conf'; config.write_text('set -g remain-on-exit on\n')
    subprocess.run([TMUX, '-S', str(socket), '-f', str(config), 'new-session', '-d', '-s', 'fixture',
                    str(helper), '--request', str(request)], check=True, capture_output=True)
    try:
        text = ''
        for _ in range(40):
            result = subprocess.run([TMUX, '-S', str(socket), 'capture-pane', '-p', '-t', 'fixture', '-S', '-100'], capture_output=True, text=True)
            text = result.stdout[:8000]
            if any(word in text.lower() for word in ['not found', 'no saved', 'no session', 'trust', 'log in', 'login', 'sign in', 'no conversation']): break
            time.sleep(0.25)
        state = subprocess.run([TMUX, '-S', str(socket), 'list-panes', '-F', '#{pane_dead} #{pane_dead_status}'], capture_output=True, text=True)
        # Preserve only classifications, never provider history entries or credentials.
        lower = text.lower()
        return {'execution_receipt': receipt.exists(), 'pane_state': state.stdout.strip(),
                'missing_history_reported': any(word in lower for word in ['not found', 'no saved', 'no session', 'no conversation']),
                'argument_error_reported': any(word in lower for word in ['unexpected argument', 'unknown option', 'unrecognized option']),
                'trust_gate_visible': 'trust' in lower,
                'authentication_gate_visible': any(word in lower for word in ['log in', 'login', 'sign in']),
                'response_verified': False, 'prompt_sent': False}
    finally:
        subprocess.run([TMUX, '-S', str(socket), 'kill-server'], capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = {'providers': {}, 'scope': 'Installed help and missing-history startup in an owned PTY. No model prompt, selected user history, cloud transfer, or configuration change.'}
    for name in ['codex', 'claude']:
        executable = shutil.which(name)
        if not executable:
            report['providers'][name] = {'installed': False}; continue
        _, version = help_result(executable, ['--version'])
        _, help_text = help_result(executable, ['resume', '--help'] if name == 'codex' else ['--help'])
        row = {'installed': True, 'version': version.strip(), 'resume_interface': 'resume' in help_text,
               'cloud_code_apply_interface': False, 'cloud_conversation_interface': '--teleport' in help_text,
               'remote_interface': '--remote' in help_text or '--remote-control' in help_text}
        if name == 'codex':
            _, cloud = help_result(executable, ['cloud', 'apply', '--help'])
            row['cloud_code_apply_interface'] = 'Apply the diff' in cloud
        else:
            status, remote = help_result(executable, ['remote-control', '--help'])
            row['remote_control_policy_blocked'] = status != 0 and "disabled by your organization's policy" in remote
        with tempfile.TemporaryDirectory(prefix='spookky-m4-provider-', dir='/tmp') as folder:
            root = Path(folder); (root / 'checkout').mkdir()
            session = str(uuid.uuid4())
            arguments = ['resume', session, '-C', str(root / 'checkout')] if name == 'codex' else ['--resume', session]
            if name == 'codex' and '--no-daemon' in help_text: arguments.append('--no-daemon')
            row['missing_history_startup'] = missing_history(executable, arguments, root)
        report['providers'][name] = row
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
