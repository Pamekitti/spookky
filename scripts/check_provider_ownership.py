#!/usr/bin/env python3
"""Exercise installed Codex writer arbitration in isolated, offline provider roots."""
import argparse
import base64
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'Disposable offline Spookky ownership fixture.'


def stop(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)


class RPC:
    def __init__(self, executable, environment, directory, endpoint=None):
        self.process = None
        self.connection = None
        self.buffer = b''
        self.sequence = 0
        self.provider_root = Path(environment["CODEX_HOME"])
        try:
            if endpoint:
                self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.connection.settimeout(8)
                self.connection.connect(str(endpoint))
                key = base64.b64encode(os.urandom(16)).decode()
                self.connection.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                                         'Connection: Upgrade\r\nSec-WebSocket-Key: ' + key +
                                         '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
                while b'\r\n\r\n' not in self.buffer:
                    self.buffer += self.connection.recv(4096)
                header, self.buffer = self.buffer.split(b'\r\n\r\n', 1)
                if b'101 Switching Protocols' not in header:
                    raise RuntimeError('Owned WebSocket handshake failed')
            else:
                self.process = subprocess.Popen([executable, 'app-server', '--listen', 'stdio://'],
                    env=environment, cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, start_new_session=True)
            self.request('initialize', {'clientInfo': {'name': 'spookky_ownership_fixture', 'version': '0.1'}})
            self.send({'method': 'initialized', 'params': {}})
        except Exception:
            self.close()
            raise

    def take(self, count):
        while len(self.buffer) < count:
            chunk = self.connection.recv(65536)
            if not chunk:
                raise RuntimeError('Owned socket closed')
            self.buffer += chunk
        value, self.buffer = self.buffer[:count], self.buffer[count:]
        return value

    def send(self, value):
        data = json.dumps(value).encode()
        if not self.connection:
            self.process.stdin.write(data + b'\n')
            self.process.stdin.flush()
            return
        length = len(data)
        head = bytes([129, 128 | (length if length < 126 else 126)])
        if length >= 126:
            head += struct.pack('!H', length)
        mask = os.urandom(4)
        self.connection.sendall(head + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

    def read(self):
        if self.connection:
            while True:
                head = self.take(2)
                length = head[1] & 127
                if length == 126:
                    length = struct.unpack('!H', self.take(2))[0]
                elif length == 127:
                    length = struct.unpack('!Q', self.take(8))[0]
                if length > 1_048_576:
                    raise RuntimeError('Oversized fixture response')
                mask = self.take(4) if head[1] & 128 else None
                data = self.take(length)
                if mask:
                    data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
                if head[0] & 15 in (1, 2):
                    return json.loads(data)
                if head[0] & 15 == 8:
                    raise RuntimeError('Owned WebSocket closed')
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                return json.loads(line)
            if select.select([self.process.stdout], [], [], .1)[0]:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError('Owned stdio server closed')
                self.buffer += data
            if len(self.buffer) > 1_048_576:
                raise RuntimeError('Oversized fixture response')
        raise TimeoutError('Owned metadata response timed out')

    def request(self, method, params):
        self.sequence += 1
        self.send({'id': self.sequence, 'method': method, 'params': params})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            value = self.read()
            if value.get('id') == self.sequence:
                return value
        raise TimeoutError(method)

    def start(self, directory):
        row = self.request('thread/start', {'cwd': str(directory)})
        session_id = row['result']['thread']['id']
        self.request('turn/start', {'threadId': session_id, 'input': [{'type': 'text', 'text': MARKER}]})
        for _ in range(60):
            # Wait for this fixture's initial history record, not for ownership release.
            # An in-memory thread/read response can precede the initial disk flush.
            for path in self.provider_root.rglob('*' + session_id + '.jsonl'):
                try:
                    with path.open() as handle:
                        row = json.loads(handle.readline(65_536))
                    if row.get('type') == 'session_meta' and row.get('payload', {}).get('id') == session_id:
                        return session_id
                except (ValueError, OSError):
                    pass
            time.sleep(.05)
        raise RuntimeError('Fixture history was not persisted')

    def close(self):
        if self.connection:
            self.connection.close()
        if self.process:
            stop(self.process)


def rejected(row):
    return row.get('error', {}).get('code') == -32600 and 'active writer' in row.get('error', {}).get('message', '')


def check(executable, tmux, root, owner_executable=None):
    owner_executable = owner_executable or executable
    codex_home, checkout = root / 'provider', root / 'checkout'
    codex_home.mkdir(mode=0o700)
    checkout.mkdir()
    (codex_home / 'config.toml').write_text('''model_provider = "spookky_fixture"
model = "fixture"
check_for_update_on_startup = false
[model_providers.spookky_fixture]
name = "Offline fixture"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
''')
    environment = {k: v for k, v in os.environ.items() if not k.startswith('CODEX_')
                   and not k.endswith(('_API_KEY', '_ACCESS_TOKEN', '_OAUTH_TOKEN'))}
    environment.update(CODEX_HOME=str(codex_home), NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')
    checks = {}
    observations = {"same_server_metadata_retries": 0}
    first = second = server = client = peer = None
    private_socket = root / 'tmux.sock'
    try:
        first = RPC(owner_executable, environment, checkout)
        first_id = first.start(checkout)
        second = RPC(executable, environment, checkout)
        other_id = second.start(checkout)
        checks['unrelated_conversation_allowed_with_provider_owner_present'] = first_id != other_id
        checks['independent_writer_refused'] = rejected(second.request('thread/resume', {'threadId': first_id, 'excludeTurns': True}))
        checks['same_owner_resume_same_id'] = first.request('thread/resume', {'threadId': first_id, 'excludeTurns': True}).get('result', {}).get('thread', {}).get('id') == first_id
        first.close()
        first = None
        checks['resume_after_owned_server_exit'] = second.request('thread/resume', {'threadId': first_id, 'excludeTurns': True}).get('result', {}).get('thread', {}).get('id') == first_id
        second.close()
        second = None
        endpoint = root / 'server.sock'
        server = subprocess.Popen([owner_executable, 'app-server', '--listen', 'unix://' + str(endpoint)],
            env=environment, cwd=checkout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(100):
            if endpoint.exists():
                break
            time.sleep(.05)
        client = RPC(executable, environment, checkout, endpoint)
        session_id = client.start(checkout)
        peer = RPC(executable, environment, checkout, endpoint)
        for _ in range(40):
            resumed = peer.request('thread/resume', {'threadId': session_id, 'excludeTurns': True})
            error = resumed.get('error', {})
            if error.get('code') != -32603 or not any(word in error.get('message', '') for word in ['rollout', 'metadata', 'failed to read thread']):
                break
            observations['same_server_metadata_retries'] += 1
            time.sleep(.05)
        checks['same_server_second_client_same_id'] = resumed.get('result', {}).get('thread', {}).get('id') == session_id
        config = root / 'tmux.conf'
        config.write_text('set -g remain-on-exit on\n')
        def command(*arguments):
            return subprocess.run([tmux, '-S', str(private_socket), *arguments], capture_output=True, text=True, timeout=5)
        command('-f', str(config), 'new-session', '-d', '-s', 'owned-tui', '-x', '140', '-y', '45', '-c', str(checkout),
                '/usr/bin/env', 'CODEX_HOME=' + str(codex_home), executable, 'resume', session_id,
                '--remote', 'unix://' + str(endpoint), '--cd', str(checkout), '--no-alt-screen').check_returncode()
        accepted_fixture_trust = False
        for _ in range(80):
            visible = command('capture-pane', '-p', '-t', 'owned-tui').stdout
            if 'Trust this folder?' in visible and str(checkout) in visible and not accepted_fixture_trust:
                command('send-keys', '-t', 'owned-tui', 'Enter').check_returncode()
                accepted_fixture_trust = True
            if MARKER in visible and 'Trust this folder?' not in visible:
                break
            time.sleep(.1)
        checks['native_tui_rejoins_saved_history'] = MARKER in visible and 'Trust this folder?' not in visible
        checks['native_tui_preserves_original_checkout'] = str(checkout) in command('capture-pane', '-p', '-t', 'owned-tui', '-S', '-100').stdout
        loaded = client.request('thread/loaded/list', {})
        checks['native_attach_keeps_one_engine'] = loaded.get('result', {}).get('data') == [session_id]
        files = list(codex_home.rglob('*' + session_id + '.jsonl'))
        starts = 0
        for path in files:
            for line in path.read_text().splitlines():
                row = json.loads(line)
                starts += row.get('type') == 'event_msg' and row.get('payload', {}).get('type') == 'task_started'
        checks['native_attach_does_not_start_another_turn'] = starts == 1
        return checks, observations
    finally:
        subprocess.run([tmux, '-S', str(private_socket), 'kill-server'], capture_output=True, timeout=5)
        for owned in (first, second, client, peer):
            if owned:
                owned.close()
        if server:
            stop(server)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--executable', default=shutil.which('codex'))
    parser.add_argument('--owner-executable', help='Optional installed Codex server binary for cross-version locking checks')
    args = parser.parse_args()
    executable = args.executable
    tmux = ROOT / '.cache/runtime/bin/tmux'
    if not executable or not tmux.is_file():
        raise SystemExit('Installed Codex and the pinned private tmux runtime are required.')
    version = subprocess.check_output([executable, '--version'], text=True, timeout=3).strip()
    owner_version = subprocess.check_output([args.owner_executable or executable, '--version'], text=True, timeout=3).strip()
    with tempfile.TemporaryDirectory(prefix='spookky-writer-check-', dir='/private/tmp') as directory:
        checks, observations = check(executable, str(tmux), Path(directory), args.owner_executable)
    report = {'provider': version, 'ownerProvider': owner_version, 'checks': checks, 'observations': observations, 'pass': all(checks.values()),
              'scope': 'Offline disposable provider roots, no real credentials, no model service, no remote pairing or user sessions.'}
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['pass'] else 1)


if __name__ == '__main__':
    main()
