#!/usr/bin/env python3
"""Verify the synthetic 600-conversation sidebar and one owned fake provider."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from native_fixture import native_fixture, NATIVE_BINARY


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--background', action='store_true', help='Keep the owned fixture behind user windows; excludes physical input verification')
    parser.add_argument('--hold', action='store_true', help='Keep the owned fixture open until Return for native inspection')
    args = parser.parse_args()
    arguments = ['--workspace-benchmark-count', '0', '--workspace-benchmark-history']
    if not args.background:
        arguments.append('--workspace-benchmark-front')
    with native_fixture(arguments,
                        prefix='spookky-m1-history-', binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(90, 'History sidebar fixture failed')
        except Exception:
            for name in ['app.log', 'history-checks.json']:
                source = fixture.root / name
                if source.exists():
                    shutil.copy2(source, args.output.parent / ('history-failed-' + name))
            raise
        checks = fixture.read_checks('history-checks.json')
        resources = json.loads((fixture.root / 'history-resources.json').read_text())
        report = dict(background=args.background, checks=checks, resources=resources, binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                      scope='Synthetic metadata, fake provider CLI, owned native app/private runtime. No real provider or browser engine compatibility claim.')
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        for theme in ['dark', 'light']:
            shutil.copy2(fixture.root / ('history-' + theme + '.png'), args.output.parent / ('history-sidebar-' + theme + '.png'))
        if not checks or not all(checks.values()):
            raise SystemExit('History sidebar assertions failed')
        print(json.dumps(report, indent=2), flush=True)
        if args.hold:
            (args.output.parent / 'history-gui-target.json').write_text(json.dumps(dict(pid=fixture.process.pid, root=str(fixture.root))))
            input('Owned history fixture ready; press Return to close it: ')


if __name__ == '__main__':
    main()
