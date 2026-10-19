#!/usr/bin/env python3
"""Exercise real session lifecycles and checkpoint an isolated continuity run."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path

from benchmark_m0 import cpu_seconds
from benchmark_m1 import measure_settled, timing
from benchmark_m3 import prepare
from native_fixture import NATIVE_BINARY, TMUX, native_fixture


def cycle_summary(rows, *, require_full_run=True):
    measured = [row for row in rows if not row['warmup']]
    blocks = [statistics.median(row['rssMiB'] for row in measured[i:i+20]) for i in range(0, len(measured), 20)]
    sustained_growth = len(blocks) == 5 and all(b > a + 2 for a, b in zip(blocks, blocks[1:])) and blocks[-1] - blocks[0] > 10
    checks = {
        'closed_processes_gone': all(row['closedProcessGone'] for row in rows),
        'ten_baseline_sessions': all(row['remainingSessions'] == 10 for row in rows),
        'surface_limit': all(row['surfaces'] <= 3 for row in rows),
        'file_task_handle_limit': all(row['fileTaskHandles'] <= 2 for row in rows),
        'resize_task_handle_limit': all(row['resizeTaskHandles'] <= 3 for row in rows),
        'settled_launch_operations': all(row['launchOperations'] == 0 for row in rows),
        'composer_limit': all(row['composers'] <= 10 for row in rows),
        'watcher_limit': all(row['watchers'] <= 1 for row in rows),
        'preview_limit': all(row['previewBytes'] <= 64 * 1024 * 1024 for row in rows),
        'metadata_limit': all(row['metadataBytes'] <= 16 * 1024 * 1024 for row in rows),
        'no_sustained_rss_growth': not sustained_growth,
    }
    if require_full_run:
        checks.update(ten_warmups=sum(row['warmup'] for row in rows) == 10,
                      hundred_measured_cycles=len(measured) == 100)
    return {'checks': checks, 'rss_20_cycle_block_medians_mib': blocks,
            'growth_rule': 'All four block increases exceed 2 MiB and total increase exceeds 10 MiB flags allocation investigation. Passing is bounded-cycle evidence, not an overnight plateau guarantee.',
            'failure_count': sum(not value for value in checks.values()), 'rows': rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=1800)
    parser.add_argument('--overnight', action='store_true', help='Eight-hour run; does not prevent system sleep')
    parser.add_argument('--smoke', action='store_true', help='Two lifecycle cycles and a one-second diagnostic workload; no performance acceptance')
    parser.add_argument('--skip-timing', action='store_true')
    parser.add_argument('--background', action='store_true', help='Keep the fixture behind user windows; records the visibility boundary')
    parser.add_argument('--output', required=True)
    parser.add_argument('--binary', type=Path, default=NATIVE_BINARY, help='Frozen isolated app executable; also used for crash recovery')
    parser.add_argument('--output-delay', type=float, default=0, help='Smoke-only delayed-output startup fixture, in seconds (0 to 5)')
    args = parser.parse_args()
    if not 0 <= args.output_delay <= 5 or (args.output_delay and not args.smoke): parser.error('--output-delay requires --smoke and a value from zero to five')
    seconds = 1 if args.smoke else (28800 if args.overnight else args.seconds)
    if not 1 <= seconds <= 28800: parser.error('Duration must be from 1 to 28800 seconds')
    path = Path(args.output); path.parent.mkdir(parents=True, exist_ok=True)
    result = {'machine': platform.platform(), 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              'binary': str(args.binary.resolve()),
              'requested_seconds': seconds, 'mode': 'overnight' if args.overnight else 'continuity',
              'foreground': not args.background,
              'boundary': 'Generated shell drafts and output, actual owned-session creation/termination, native view attachment and Git/file refresh. Excludes physical display latency and provider responses.',
              'state': 'running'}
    def save():
        temporary = path.with_suffix(path.suffix + '.pending')
        temporary.write_text(json.dumps(result, indent=2) + '\n'); temporary.replace(path)
    save()
    try:
        with native_fixture(['--workspace', '--workspace-measure', '--workspace-benchmark-count', '10',
                             '--workspace-benchmark-files', '--workspace-benchmark-continuity', str(seconds),
                             *([] if args.background else ['--workspace-benchmark-front']), '--workspace-benchmark-cycle-count', '2' if args.smoke else '110',
                             '--workspace-benchmark-output-delay', str(args.output_delay)], prefix='spookky-m1-m4-', binary=args.binary, workspace=True, prepare=prepare) as fixture:
            result['fixture_root'] = str(fixture.root); save()
            result['app_memory_samples'] = []
            result['memory_sample_boundary'] = 'App RSS and cumulative CPU observed every 30 seconds while waiting for continuity and once after completion. Runtime and shell totals are measured separately after the workload. RSS includes shared pages and can change with compression.'
            observation_started = time.monotonic()
            def sample_app_memory():
                sample = subprocess.run(['ps', '-p', str(fixture.process.pid), '-o', 'rss=,time='],
                                        capture_output=True, text=True, timeout=5).stdout.split()
                result['app_memory_samples'].append({'elapsed_seconds': time.monotonic() - observation_started,
                    'pid': fixture.process.pid, 'rss_mib': int(sample[0]) / 1024 if sample else None,
                    'cpu_seconds': cpu_seconds(sample[1]) if sample else None})
            deadline = time.monotonic() + seconds + 600
            while not (fixture.root / 'ready.json').exists():
                if fixture.process.poll() is not None or time.monotonic() > deadline:
                    for key, filename in [('cycles', 'continuity-cycles.json'), ('checkpoints', 'continuity-checkpoints.json')]:
                        source = fixture.root / filename
                        if source.exists(): result[key] = json.loads(source.read_text())
                    for key, filename in [('owner_actions', 'runtime-actions.json'), ('baseline_identities', 'baseline-identities.json'), ('draft_failure', 'draft-failure.json'), ('fixture_failure', 'continuity-failure.json')]:
                        source = fixture.root / filename
                        if source.exists(): result[key] = json.loads(source.read_text())
                    if (fixture.root / 'socket').exists():
                        panes = subprocess.run([TMUX, '-S', str(fixture.root / 'socket'), 'list-panes', '-a',
                                                '-F', '#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_width}x#{pane_height}\t#{pane_dead}'],
                                               capture_output=True, text=True, timeout=5)
                        result['failed_fixture_panes'] = panes.stdout[:8192]
                        result['failed_fixture_screens'] = {}
                        for line in panes.stdout.splitlines()[:12]:
                            pane = line.split('\t')[0]
                            screen = subprocess.run([TMUX, '-S', str(fixture.root / 'socket'), 'capture-pane', '-p', '-t', pane],
                                                    capture_output=True, text=True, timeout=5)
                            result['failed_fixture_screens'][pane] = screen.stdout[:4096]
                    raise RuntimeError('Continuity fixture failed: ' + (fixture.root / 'app.log').read_text()[-2000:])
                for key, filename in [('cycles', 'continuity-cycles.json'), ('checkpoints', 'continuity-checkpoints.json')]:
                    source = fixture.root / filename
                    if source.exists(): result[key] = json.loads(source.read_text())
                sample_app_memory()
                save()
                print(json.dumps({'cycles': len(result.get('cycles', [])), 'checkpoints': len(result.get('checkpoints', [])), 'elapsed': result.get('checkpoints', [{}])[-1].get('elapsedSeconds', 0)}), flush=True)
                time.sleep(30)
            sample_app_memory()
            result['cycles'] = cycle_summary(json.loads((fixture.root / 'continuity-cycles.json').read_text()), require_full_run=not args.smoke)
            result['checkpoints'] = json.loads((fixture.root / 'continuity-checkpoints.json').read_text())
            result['continuity'] = json.loads((fixture.root / 'continuity-result.json').read_text())
            result['output_startup'] = {**json.loads((fixture.root / 'output-ready.json').read_text()),
                                        'boundary': 'Initial native output attachment through first generated line in terminal state. Outside the timed continuity workload.'}
            result['post_workload_resources'] = measure_settled(fixture, 10, 60, foreground=not args.background) if not args.smoke else {'failure_count': 0, 'idle_cpu_percent_one_core': None}
            save()
        if not args.skip_timing and not args.smoke: result['timing'] = timing(resize=True, binary=args.binary,
                                                                            extra_arguments=['--workspace-benchmark-files'], prepare=prepare)
        if not args.smoke:
            result['continuity_checks'] = {
                'duration_completed': result['continuity']['elapsedSeconds'] >= seconds,
                'file_task_handles_bounded': all(row['fileTaskHandles'] <= 2 for row in result['checkpoints']),
                'resize_task_handles_bounded': all(row['resizeTaskHandles'] <= 3 for row in result['checkpoints']),
                'reconciliation_task_handles_bounded': all(row['reconciliationTaskHandles'] <= 1 for row in result['checkpoints']),
                'render_task_handles_bounded': all(row['renderTaskHandles'] <= 1 for row in result['checkpoints']),
            }
            if 'timing' in result:
                result['continuity_checks']['warm_switch_budget'] = result['timing']['warm_selection']['p95_ms'] < 100
                result['continuity_checks']['reattachment_budget'] = result['timing']['recreated_surface_selection']['p95_ms'] < 250
        if args.background:
            result.setdefault('continuity_checks', {})['no_keyboard_focus'] = bool(result['checkpoints']) and all(row['windowKey'] == 0 and row['windowMain'] == 0 for row in result['checkpoints'])
        result['binary_changed_during_run'] = hashlib.sha256(args.binary.read_bytes()).hexdigest() != result['binary_sha256']
        if args.smoke:
            result['performance_acceptance'] = False
        result['failure_count'] = result['cycles']['failure_count'] + result['post_workload_resources']['failure_count'] + sum(r['failure_count'] for r in result.get('timing', {}).values())
        cpu = result['post_workload_resources']['idle_cpu_percent_one_core']
        result['idle_cpu_budget_passed'] = cpu is not None and cpu < 1
        result['failure_count'] += sum(not value for value in result.get('continuity_checks', {}).values())
        result['failure_count'] += int(not args.smoke and not result['idle_cpu_budget_passed']) + int(result['binary_changed_during_run'])
        result['state'] = 'completed'; save()
    except BaseException as error:
        result['state'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        result['error'] = str(error); save(); raise
    if result['failure_count']: raise SystemExit('Failed continuity check; inspect report')
    print(str(path), flush=True)


if __name__ == '__main__': main()
