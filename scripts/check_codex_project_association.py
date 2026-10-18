#!/usr/bin/env python3
"""Verify project APIs on disposable provider state without a model request."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time


class RPC:
    def __init__(self, executable, environment, directory):
        started = time.monotonic()
        self.process = subprocess.Popen([executable, 'app-server'], cwd=directory, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.pending = b''
        self.sequence = 0
        try:
            self.request('initialize', {'clientInfo': {'name': 'spookky_project_fixture', 'version': '0.1'},
                                        'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized'})
            self.initialization_seconds = time.monotonic() - started
        except Exception:
            self.close()
            raise

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        self.send({'id': self.sequence, 'method': method, 'params': params})
        deadline = time.monotonic() + 15
        received = 0
        while time.monotonic() < deadline:
            if b'\n' not in self.pending:
                if not self.selector.select(timeout=max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(self.process.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError('Provider connection closed')
                self.pending += chunk
                received += len(chunk)
                if received > 1_048_576:
                    raise RuntimeError('Provider response exceeded fixture limit')
                continue
            line, self.pending = self.pending.split(b'\n', 1)
            response = json.loads(line)
            if response.get('id') != self.sequence:
                continue
            if 'error' in response:
                raise RuntimeError(str(response['error']['code']) + ': ' + response['error']['message'])
            return response['result']
        raise RuntimeError('Provider metadata request timed out')

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.process.stdout.close()


def resources(process_id):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss='], text=True).splitlines()
    processes = [tuple(map(int, row.split())) for row in rows]
    owned = {process_id}
    previous = set()
    while previous != owned:
        previous = set(owned)
        owned.update(pid for pid, parent, _ in processes if parent in owned)
    return {'owned_process_count': len(owned),
            'owned_rss_mib': sum(rss for pid, _, rss in processes if pid in owned) / 1024}


def verify(executable):
    try:
        probe = subprocess.run([executable, '--version'], capture_output=True, text=True, timeout=3)
        version = (probe.stdout + probe.stderr).strip()[:128] if probe.returncode == 0 else 'Unavailable'
    except (OSError, subprocess.TimeoutExpired):
        version = 'Unavailable'
    report = {'version': version, 'disposable_state': True, 'model_requests': 0}
    with tempfile.TemporaryDirectory(prefix='spookky-project-association-') as folder:
        root = Path(folder).resolve()
        repo = root / 'original'
        repo.mkdir()
        for args in [['init', '-b', 'main'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                                            'commit', '--allow-empty', '-m', 'fixture']]:
            subprocess.run(['/usr/bin/git', '-C', str(repo), *args], check=True, capture_output=True)
        directories = [repo]
        for branch in ['one', 'two']:
            checkout = root / ('generated-' + branch)
            subprocess.run(['/usr/bin/git', '-C', str(repo), 'worktree', 'add', '-b', branch, str(checkout)],
                           check=True, capture_output=True)
            directories.append(checkout)
        sub = directories[-1] / 'src'
        sub.mkdir()
        directories[-1] = sub
        home = root / 'home'
        state = root / 'provider'
        home.mkdir()
        state.mkdir()
        environment = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home), 'CODEX_HOME': str(state)}
        rpc = RPC(executable, environment, root)
        ids = []
        try:
            project = rpc.request('project/create', {'idempotencyKey': 'fixture-project', 'name': 'Fixture',
                                                     'roots': [{'path': str(repo)}]})['project']
            started = time.monotonic()
            listed = rpc.request('project/list', {'limit': 64})['data']
            report['metadata_connection_snapshot'] = dict(resources(rpc.process.pid),
                initialization_seconds=rpc.initialization_seconds, list_seconds=time.monotonic() - started)
            report['registered_project_visible'] = any(p['id'] == project['id'] for p in listed)
            for directory in directories:
                thread = rpc.request('thread/start', {'cwd': str(directory), 'model': 'fixture-model',
                                                      'modelProvider': 'openai', 'historyMode': 'paginated'})['thread']
                thread_id = thread['id']
                # This is an owned fixture shell builtin, not a model turn or a user conversation.
                rpc.request('thread/shellCommand', {'threadId': thread_id, 'command': ':', 'timeoutMs': 1000})
                deadline = time.monotonic() + 5
                while True:
                    try:
                        rpc.request('thread/metadata/update', {'threadId': thread_id, 'projectId': project['id']})
                        break
                    except RuntimeError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.05)
                ids.append((thread_id, str(directory)))
        finally:
            rpc.close()
        rpc = RPC(executable, environment, root)
        try:
            checks = []
            for thread_id, directory in ids:
                thread = rpc.request('thread/read', {'threadId': thread_id, 'includeTurns': False})['thread']
                checks.append({'project_preserved': thread.get('projectId') == project['id'],
                               'cwd_preserved': Path(thread['cwd']).resolve() == Path(directory).resolve()})
            report['fresh_connection_checks'] = checks
            report['passed'] = report['registered_project_visible'] and all(all(item.values()) for item in checks)
        finally:
            rpc.close()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', action='append', help='Installed Codex executable, repeat for multiple versions')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    executables = args.executable or [shutil.which('codex')]
    if not all(executables):
        raise SystemExit('Codex was not found')
    report = {'scope': 'Disposable registrations and conversations only. No model turns, credentials, or existing membership changes.',
              'providers': [verify(executable) for executable in executables]}
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not all(item['passed'] for item in report['providers']):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
