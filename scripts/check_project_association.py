#!/usr/bin/env python3
"""Verify primary-conversation association UI with disposable shells and metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from native_fixture import native_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('DerivedData/Build/Products/Debug/Spookky.app/Contents/MacOS/Spookky'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    with native_fixture(['--workspace-benchmark-count', '0', '--workspace-benchmark-project-association', '--workspace-benchmark-front'],
                        prefix='spookky-m1-project-association-', binary=binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(45, 'Native project association check failed')
        except Exception:
            for name in ['app.log', 'project-association-checks.json', 'continuity-failure.json']:
                source = fixture.root / name
                if source.exists():
                    shutil.copy2(source, args.output.parent / ('failed-grouping-' + name))
            raise
        checks = json.loads((fixture.root / 'project-association-checks.json').read_text())
        required = {'primary_row_exposes_limitation', 'primary_row_refreshes_without_recreation',
                    'support_focus_does_not_change_owner', 'association_is_presented_on_conversation_row',
                    'same_checkout_has_distinct_conversation_entries', 'project_assignment_preserves_execution_directory',
                    'hidden_result_retains_closed_view_and_selection', 'association_preserves_primary_process_and_input',
                    'association_preserves_support_input', 'metadata_valid'}
        if set(checks) != required:
            raise RuntimeError('Association fixture report is incomplete')
        screenshots = []
        for size in ['dark-wide', 'light-narrow']:
            name = 'project-association-' + size + '.png'
            destination = args.output.with_name(args.output.stem + '-' + size + '.png')
            shutil.copy2(fixture.root / name, destination)
            screenshots.append(str(destination))
    report = {'binary_sha256': digest, 'checks': checks, 'screenshots': screenshots,
              'binary_changed': hashlib.sha256(binary.read_bytes()).hexdigest() != digest,
              'boundary': 'Synthetic provider association metadata with real disposable shells. No Codex/Claude request, real history mutation, or browser host verification.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not all(checks.values()) or report['binary_changed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
