#!/usr/bin/env python3
"""Check retained native text selection in an owned terminal fixture."""
import argparse
import hashlib
import json
from pathlib import Path
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    with native_fixture(['--workspace-benchmark-count', '1', '--workspace-benchmark-selection'],
                        prefix='spookky-m1-selection-', binary=args.binary, workspace=True) as fixture:
        try:
            fixture.wait_ready(90, 'Native terminal selection failed')
        except Exception:
            evidence = fixture.preserve_evidence(output, ['app.log', 'selection-checks.json', 'selection-timing.json'])
            print('Selection failure evidence: ' + str(evidence), flush=True)
            raise
        checks = fixture.read_checks('selection-checks.json')
        required = {'exact_native_selection', 'highlight_retained_after_release', 'copy_matches_selection',
                    'process_unchanged', 'no_tmux_copy_mode'}
        if set(checks) != required:
            raise SystemExit('Selection fixture is stale or its report is incomplete')
        timing = json.loads((fixture.root / 'selection-timing.json').read_text())
    result = {'binary_sha256': digest, 'checks': checks, 'timing': timing,
              'failure_count': sum(not value for value in checks.values()),
              'boundary': 'Native view mouse handlers and real Ghostty selection. Generated text only. Physical pointer and fullscreen remain separate checks.'}
    result['binary_changed_during_run'] = hashlib.sha256(args.binary.read_bytes()).hexdigest() != digest
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if result['failure_count'] or result['binary_changed_during_run']:
        raise SystemExit('Native terminal selection failed')


if __name__ == '__main__':
    main()
