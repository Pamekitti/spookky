#!/usr/bin/env python3
"""Measure selected previews and owned shell fixtures with M3 visible or hidden."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import platform
import time
import benchmark_m1
from benchmark_m0 import summarize
from native_fixture import native_fixture, NATIVE_BINARY


def prepare(root, dense=False):
    code = root / 'code'
    code.mkdir()
    (root / 'other').mkdir()
    def git(*args):
        subprocess.run(['/usr/bin/git', '-C', str(code), *args], check=True, capture_output=True)
    git('init', '--initial-branch=dev')
    git('config', 'user.name', 'Spookky Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    original = ''.join(f'{i:05} ' + 'x' * 201 + '\n' for i in range(5000))
    for name in ['sample.swift', 'other.swift']:
        (code / name).write_text(original)
    git('add', '.')
    git('commit', '-m', 'Fixture')
    # Half the lines change: about one MiB and 5,000 diff rows, plus context.
    changed = original.replace("x", "y") if dense else original[:len(original)//2].replace("x", "y") + original[len(original)//2:]
    for name in ['sample.swift', 'other.swift']:
        (code / name).write_text(changed if name == "sample.swift" else changed.replace("y", "z"))


def wrapped_fixture(arguments, **kwargs):
    return native_fixture([*arguments, '--workspace-benchmark-files'], prepare=prepare, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['diff', 'timing', 'resources'], default='diff')
    parser.add_argument('--panel', choices=['open', 'closed'], default='open')
    parser.add_argument('--output', required=True)
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY, help='Isolated app executable; defaults to the Release build')
    parser.add_argument('--foreground-wait', type=float, default=0, help='Seconds to allow foreground activation before resource warm-up')
    parser.add_argument('--dense', action='store_true', help='Stress case: change every line, producing about twice the standard diff size')
    args = parser.parse_args()
    if args.dense and args.mode != "diff": parser.error("--dense is only supported for diff measurements")
    if args.foreground_wait < 0 or args.foreground_wait > 60: parser.error('--foreground-wait must be between 0 and 60 seconds')
    result = {'machine': platform.platform(), 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'mode': args.mode, 'workload': 'dense: about 2 MiB / 10000 diff rows' if args.dense else 'standard: about 1 MiB / 5000 diff rows'}
    if args.mode == 'diff':
        with native_fixture(['--workspace', '--workspace-measure', '--workspace-benchmark-count', '1', '--workspace-benchmark-files', '--workspace-benchmark-diffs', '--workspace-benchmark-front'], prefix='spookky-m1-m3-diff-', binary=args.binary, workspace=True, prepare=lambda root: prepare(root, dense=args.dense)) as fixture:
            try:
                fixture.wait_ready(600, 'File preview benchmark did not finish.')
            except RuntimeError as error:
                result.update({'failure_count': 1, 'fixture_completed': False, 'failure': str(error)})
                for name, key in [('file-timings.json', 'partial_preview_values'), ('file-phases.json', 'partial_phase_timings')]:
                    checkpoint = fixture.root / name
                    if checkpoint.exists(): result[key] = json.loads(checkpoint.read_text())
                Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
                raise
            values = json.loads((fixture.root / 'file-timings.json').read_text())
            cycles = json.loads((fixture.root / 'file-cycles.json').read_text())
            summary = summarize(values)
            result.update({'metric': 'selected diff milliseconds', 'boundary': 'Selection through Git read, parsing, native table reload and layout; excludes physical display latency', 'warmups': 5, 'sample_count': summary['sample_count'], 'values': values, 'median': summary['median_ms'], 'p95': summary['p95_ms'], 'failure_count': 0, 'cycle_boundary': '100 selections without waiting for background syntax, followed by a final syntax settle', 'cycles': cycles, 'phase_timings': json.loads((fixture.root / 'file-phases.json').read_text()), 'interaction_checks': json.loads((fixture.root / 'file-interactions.json').read_text())})
    elif args.mode == 'timing':
        result['timing'] = benchmark_m1.timing(resize=False, binary=args.binary,
                                             extra_arguments=['--workspace-benchmark-files'], prepare=prepare)
    else:
        result['panel'] = args.panel
        arguments = ['--workspace', '--workspace-measure', '--workspace-benchmark-count', '10', '--workspace-benchmark-front']
        if args.panel == 'open': arguments.append('--workspace-benchmark-files')
        with native_fixture(arguments, prefix='spookky-m1-m3-idle-', binary=args.binary, workspace=True,
                            prepare=prepare if args.panel == 'open' else None) as fixture:
            fixture.wait_ready(90, 'Workspace fixture did not become ready.')
            print(json.dumps({'foreground_fixture_pid': fixture.process.pid, 'root': str(fixture.root)}), flush=True)
            time.sleep(args.foreground_wait)
            result['resources'] = benchmark_m1.measure_settled(fixture, 10, 60, foreground=True)
    if args.mode == 'diff':
        phases = result['phase_timings']
        syntax_values = [value['syntax_ready_ms'] for value in phases if 'syntax_ready_ms' in value]
        if syntax_values:
            result['syntax_ready'] = summarize(syntax_values)
        cycles = result['cycles']
        checks = dict(result['interaction_checks'])
        checks.update({'thirty_observations': result['sample_count'] == 30,
                       'hundred_cycles': len(cycles) == 100,
                       'preview_budget': all(r['previewBytes'] <= 64 * 1024 * 1024 for r in cycles),
                       'metadata_budget': all(r['metadataBytes'] <= 16 * 1024 * 1024 for r in cycles),
                       'surface_limit': all(r['surfaces'] <= 3 for r in cycles),
                       'watcher_limit': all(r['watchers'] <= 1 for r in cycles)})
        if not args.dense:
            checks['diff_p95_under_150ms'] = result['p95'] < 150
            if syntax_values:
                checks['syntax_p95_under_300ms'] = result['syntax_ready']['p95_ms'] < 300
                checks['syntax_colored'] = all(value.get('syntax_colored') == 1 for value in phases)
        result['checks'] = checks
        result['failure_count'] = sum(not value for value in checks.values())
    elif args.mode == 'timing':
        result['failure_count'] = sum(v['failure_count'] for v in result['timing'].values())
    else:
        cpu = result['resources']['idle_cpu_percent_one_core']
        result['idle_cpu_budget_passed'] = cpu is not None and cpu < 1
        result['foreground_observed'] = all(result['resources']['visible_at_cpu_boundaries']) and all(result['resources']['active_at_cpu_boundaries'])
        result['failure_count'] = result['resources']['failure_count'] + int(not result['idle_cpu_budget_passed']) + int(not result['foreground_observed'])
    result['binary_changed_during_run'] = hashlib.sha256(args.binary.read_bytes()).hexdigest() != result['binary_sha256']
    destination = Path(args.output); destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('values','cycles','phase_timings')}, indent=2))
    if result['failure_count'] or result['binary_changed_during_run']: raise SystemExit('Benchmark contains a failed check; inspect the report.')

if __name__ == '__main__': main()
