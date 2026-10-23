#!/usr/bin/env python3
"""Verify sidebar appearance, hover actions, title movement and bounded native rows."""
import argparse
import json
import hashlib
from pathlib import Path
import shutil
from fixture_results import validate_checks
from native_fixture import native_fixture, NATIVE_BINARY


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--external-captures', action='store_true', help='Pause each variant for an external native screenshot and captured-VARIANT marker')
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    def binary_hash():
        with args.binary.open('rb') as source:
            return hashlib.file_digest(source, 'sha256').hexdigest()
    digest = binary_hash()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.unlink(missing_ok=True)
    evidence = args.output.parent / (args.output.stem + '-images')
    evidence.mkdir(exist_ok=True)
    for previous in evidence.glob('reference-*.png'):
        previous.unlink()
    for name in ['sidebar-reference-checks.json', 'sidebar-reference-resources.json', 'sidebar-reference-diagnostics.json', 'app.log']:
        (evidence / name).unlink(missing_ok=True)
    arguments = ['--workspace-benchmark-count', '0', '--workspace-benchmark-sidebar-reference', '--workspace-benchmark-front']
    if args.external_captures:
        arguments.append('--workspace-benchmark-sidebar-external-captures')
    with native_fixture(arguments,
                        prefix='spookky-m1-sidebar-reference-', binary=args.binary, workspace=True) as fixture:
        if args.external_captures:
            print('External capture root: ' + str(fixture.root), flush=True)
        try:
            fixture.wait_ready(300 if args.external_captures else 120, 'Sidebar reference verification failed')
        finally:
            for path in fixture.root.glob('reference-*.png'):
                shutil.copy2(path, evidence / path.name)
            for name in ['sidebar-reference-checks.json', 'sidebar-reference-resources.json', 'sidebar-reference-diagnostics.json', 'app.log']:
                path = fixture.root / name
                if path.exists():
                    shutil.copy2(path, evidence / name)
        checks = fixture.read_checks('sidebar-reference-checks.json')
        resources = json.loads((fixture.root / 'sidebar-reference-resources.json').read_text())
        validate_checks(checks, {'recycled-rows-bounded', 'ungrouped-icon-alignment', 'collapsed-nested-icon-centered'})
        if binary_hash() != digest: raise RuntimeError('Harness binary changed during verification')
        report = dict(passed=all(checks.values()), binarySHA256=digest, checks=checks, resources=resources,
                      boundary='Native AppKit rows, deterministic pointer/focus and synthetic activity/PR data. Each app CPU sample combines active half-second intervals totaling at least five seconds. Focus-loss intervals, providers and WindowServer are excluded. Provider flows and terminal input have separate checks.')
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(dict(passed=report['passed'], assertions=len(checks), resources=resources)))
        if not report['passed']:
            raise SystemExit('Sidebar reference checks failed')


if __name__ == '__main__':
    main()
