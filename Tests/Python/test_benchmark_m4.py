import unittest
from benchmark_m4 import cycle_summary


class ContinuityReportTests(unittest.TestCase):
    def rows(self):
        return [dict(index=i, warmup=i < 10, surfaces=2, watchers=1, previewBytes=100,
                     metadataBytes=200, composers=10, fileTaskHandles=2, resizeTaskHandles=0, launchOperations=0, rssMiB=100, closedProcessGone=True,
                     remainingSessions=10) for i in range(110)]

    def test_warmups_are_excluded_and_growth_is_flagged(self):
        rows = self.rows()
        rows[0]['rssMiB'] = 999
        result = cycle_summary(rows)
        self.assertEqual(result['rss_20_cycle_block_medians_mib'], [100] * 5)
        self.assertEqual(result['failure_count'], 0)
        for i, row in enumerate(rows[10:]): row['rssMiB'] = 100 + (i // 20) * 4
        self.assertFalse(cycle_summary(rows)['checks']['no_sustained_rss_growth'])

    def test_closed_process_and_surface_leaks_fail(self):
        rows = self.rows()
        rows[-1]['closedProcessGone'] = False
        rows[-1]['surfaces'] = 4
        result = cycle_summary(rows)
        self.assertFalse(result['checks']['closed_processes_gone'])
        self.assertFalse(result['checks']['surface_limit'])

    def test_smoke_omits_sample_counts_but_keeps_resource_checks(self):
        rows = self.rows()[:2]
        result = cycle_summary(rows, require_full_run=False)
        self.assertNotIn('ten_warmups', result['checks'])
        self.assertNotIn('hundred_measured_cycles', result['checks'])
        self.assertEqual(result['failure_count'], 0)
        rows[-1]['closedProcessGone'] = False
        self.assertFalse(cycle_summary(rows, require_full_run=False)['checks']['closed_processes_gone'])
