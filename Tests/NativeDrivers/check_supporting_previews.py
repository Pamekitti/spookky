#!/usr/bin/env python3
"""Run isolated native browser/artifact fixtures against a real localhost server."""
import argparse
import functools
import http.server
import json
import os
import re
from pathlib import Path
from urllib.parse import quote
import shutil
import sqlite3
import socket
import subprocess
import tempfile
import threading
import time
from native_fixture import native_fixture

ROOT = Path(__file__).resolve().parents[2]


def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,%cpu=,args='], text=True)
    return [dict(zip(['pid', 'ppid', 'rss_kib', 'cpu_percent', 'command'], row.strip().split(None, 4)))
            for row in rows.splitlines() if len(row.strip().split(None, 4)) == 5]


def process_resources(pid, root):
    rows = processes(); owned = {str(pid)}
    owned.update(row['pid'] for row in rows if str(root) in row['command']
                 and os.path.basename(row['command'].split(' -', 1)[0].lstrip('-')) in {'tmux', 'spookky-launch'})
    for _ in range(5):
        owned.update(row['pid'] for row in rows if row['ppid'] in owned)
    def coalition(process_id):
        try:
            result = subprocess.check_output(['lsappinfo', 'info', '-only', 'LSApplicationMemberCoalitionIDKey', '-app', str(process_id)], text=True, stderr=subprocess.DEVNULL, timeout=2)
            match = re.search(r'LSApplicationMemberCoalitionIDKey"=([0-9]+)', result)
            return match.group(1) if match else None
        except (OSError, subprocess.SubprocessError):
            return None
    app_coalition = coalition(pid)
    if app_coalition:
        owned.update(row['pid'] for row in rows if 'WebKit' in row['command'] and coalition(row['pid']) == app_coalition)
    owned_rows = [dict(row, command=re.sub(r'(SPOOKKY_M0_TOKEN=)\S+', r'\1<redacted>', row['command'])) for row in rows if row['pid'] in owned]
    return {'app': [row for row in owned_rows if row['pid'] == str(pid)],
            'webkit_helpers': [row for row in owned_rows if 'WebKit' in row['command']],
            'runtime_and_other_helpers': [row for row in owned_rows if row['pid'] != str(pid) and 'WebKit' not in row['command']],
            'provider_processes': 0, 'app_coalition': app_coalition,
            'boundary': 'One RSS/process sample. WebKit XPC attribution uses the app LaunchServices coalition. ps CPU percentages are lifetime averages, not an idle CPU measurement.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'DerivedData/Build/Products/Debug/SpookkyHarness.app/Contents/MacOS/SpookkyHarness')
    parser.add_argument('--output', type=Path, default=ROOT / '.cache/browser-verification')
    parser.add_argument('--hold', type=int, default=0)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='spookky-browser-http-') as directory:
        page = Path(directory) / 'browser ไทย spaces'
        page.mkdir()
        (page / 'index.html').write_text('<!doctype html><html><head><meta charset="utf-8"><title>Fixture one</title><style>body{font:16px system-ui;padding:24px;color-scheme:light dark}input{font:inherit;padding:8px;max-width:85%}</style></head><body><h1>Local browser fixture ไทย</h1><p>Unsent form state stays in this page.</p><input aria-label="Unsent preview draft" placeholder="Type a draft"><p><a href="second.html">Second page</a></p><p><a href="mailto:test@example.invalid">External address</a></p></body></html>')
        (page / 'second.html').write_text('<html><head><title>Fixture two</title></head><body><h1>Second page</h1><a href="index.html">Back to form</a></body></html>')
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith(('/download.html', '/download.bin')):
                    payload = b'SPOOKKY_DISPOSABLE_DOWNLOAD'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html' if self.path.endswith('.html') else 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename="fixture.txt"')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if self.path.endswith('/slow.html'):
                    time.sleep(0.5)
                try:
                    super().do_GET()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=directory))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        url = f'http://127.0.0.1:{server.server_port}/{quote(page.name)}/index.html'
        saved_payload = None
        old = os.environ.get('SPOOKKY_BROWSER_FIXTURE_URL')
        os.environ['SPOOKKY_BROWSER_FIXTURE_URL'] = url
        with socket.socket() as unavailable:
            unavailable.bind(('127.0.0.1', 0))
            os.environ['SPOOKKY_BROWSER_UNAVAILABLE_URL'] = f'http://127.0.0.1:{unavailable.getsockname()[1]}/unavailable'
        try:
            with native_fixture(['--workspace-benchmark-count', '0', '--workspace-benchmark-browser', '--workspace-benchmark-front'],
                                prefix='spookky-m1-browser-', binary=args.binary, workspace=True) as fixture:
                (args.output / 'running.json').write_text(json.dumps({'pid': fixture.process.pid, 'root': str(fixture.root), 'url': url}))
                try:
                    fixture.wait_ready(120, 'Native supporting preview fixture failed')
                    checks = fixture.read_checks('browser-checks.json')
                    resource = process_resources(fixture.process.pid, fixture.root)
                    (args.output / 'resources.json').write_text(json.dumps(resource, indent=2))
                    (args.output / 'checks.json').write_text(json.dumps(checks, indent=2))
                    print(json.dumps({'pid': fixture.process.pid, 'checks': len(checks), 'failures': [name for name, passed in checks.items() if not passed], 'output': str(args.output)}), flush=True)
                    release = args.output / 'release'
                    release.unlink(missing_ok=True)
                    deadline = time.monotonic() + args.hold
                    while time.monotonic() < deadline and not release.exists():
                        time.sleep(0.2)
                    with sqlite3.connect(fixture.root / 'metadata/workspace.sqlite') as database:
                        saved_payload = json.loads(database.execute('SELECT payload FROM workspace_snapshot').fetchone()[0])
                        with sqlite3.connect(args.output / 'restore-seed.sqlite') as seed:
                            database.backup(seed)
                finally:
                    for path in fixture.root.glob('*'):
                        if path.suffix in {'.png', '.json', '.log'}:
                            shutil.copy2(path, args.output / path.name)
            def prepare_restored(root):
                metadata = root / 'metadata'; metadata.mkdir()
                for workspace in saved_payload['workspaces']:
                    if workspace.get('support'):
                        workspace['support']['layout'] = 'collapsed'
                shutil.copy2(args.output / 'restore-seed.sqlite', metadata / 'workspace.sqlite')
                with sqlite3.connect(metadata / 'workspace.sqlite') as database:
                    database.execute('UPDATE workspace_snapshot SET payload = ? WHERE id = 1', (json.dumps(saved_payload).encode(),))
            if saved_payload:
                with native_fixture(['--workspace', '--workspace-benchmark-browser-restored'], prefix='spookky-m1-browser-restored-',
                                    binary=args.binary, prepare=prepare_restored, workspace=True) as restored:
                    deadline = time.monotonic() + 30
                    report = restored.root / 'browser-restored-checks.json'
                    while not report.exists() and restored.process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.1)
                    if not report.exists():
                        raise RuntimeError('Cold browser restore failed: ' + (restored.root / 'app.log').read_text()[-1500:])
                    restored_checks = restored.read_checks(report.name)
                    (args.output / 'restored-checks.json').write_text(json.dumps(restored_checks, indent=2))
                    import hashlib
                    from fixture_results import report as fixture_report
                    combined = dict(checks, **{'restore_'+key:value for key,value in restored_checks.items()})
                    (args.output/'summary.json').write_text(json.dumps(fixture_report('supporting-previews',combined,set(combined),binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),resources=resource,evidence=[str(path) for path in args.output.glob('*.png')]),indent=2)+'\n')
        finally:
            if old is None:
                os.environ.pop('SPOOKKY_BROWSER_FIXTURE_URL', None)
            else:
                os.environ['SPOOKKY_BROWSER_FIXTURE_URL'] = old
            os.environ.pop('SPOOKKY_BROWSER_UNAVAILABLE_URL', None)
            server.shutdown()


if __name__ == '__main__':
    main()
