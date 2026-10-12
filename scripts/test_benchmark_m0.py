"""Guard CPU units and process ownership in the benchmark collector."""
import unittest

from benchmark_m0 import cpu_seconds, summarize, tree


class BenchmarkTests(unittest.TestCase):
    def test_cpu_clock_units(self):
        self.assertAlmostEqual(cpu_seconds("0:00.42"), 0.42)
        self.assertAlmostEqual(cpu_seconds("12:34.56"), 754.56)
        self.assertAlmostEqual(cpu_seconds("01:02:03.45"), 3723.45)
        self.assertAlmostEqual(cpu_seconds("2-01:02:03.45"), 176523.45)

    def test_owned_descendants_exclude_unrelated_server(self):
        table = {10: (1, 100, 1), 11: (10, 50, 2), 12: (11, 20, 3),
                 20: (1, 300, 4), 21: (20, 200, 5)}
        self.assertEqual(tree(table, [10]), {10, 11, 12})
        self.assertEqual(tree(table, [10, 20]), set(table))

    def test_nearest_rank_percentile(self):
        result = summarize(list(range(100, 0, -1)))
        self.assertEqual(result["sample_count"], 100)
        self.assertEqual(result["median_ms"], 50.5)
        self.assertEqual(result["p95_ms"], 95)


if __name__ == "__main__":
    unittest.main()
