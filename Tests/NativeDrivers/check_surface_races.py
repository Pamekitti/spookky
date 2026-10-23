#!/usr/bin/env python3
"""Hold owned viewport results while native surfaces are released."""
import argparse
import hashlib
import json
from pathlib import Path
from native_fixture import NATIVE_BINARY, native_fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    digest = hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest()
    with native_fixture(['--workspace', '--workspace-measure', '--workspace-benchmark-count', '1',
                         '--workspace-benchmark-races'], prefix='spookky-m1-m4-races-', workspace=True) as fixture:
        fixture.wait_ready(90, 'Surface race fixture failed')
        checks = fixture.read_checks('surface-races.json')
    result = {'binary_sha256': digest, 'checks': checks, 'failure_count': sum(not value for value in checks.values()),
              'boundary': 'Noncooperative delayed owned viewport results, release of real Ghostty surfaces, process identity and reattachment. Generated history only.'}
    result['binary_changed_during_run'] = hashlib.sha256(NATIVE_BINARY.read_bytes()).hexdigest() != digest
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if result['failure_count'] or result['binary_changed_during_run']: raise SystemExit('Surface race check failed')


if __name__ == '__main__': main()
