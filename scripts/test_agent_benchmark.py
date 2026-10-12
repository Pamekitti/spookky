import unittest

from benchmark_agents_m0 import groups


class AgentOwnershipTests(unittest.TestCase):
    def test_agent_children_are_separate_from_app_and_shared_services(self):
        table = {10: (1, 100, 0), 11: (10, 20, 0),
                 20: (1, 10, 0), 30: (20, 200, 0), 31: (30, 50, 0),
                 40: (1, 800, 0), 41: (40, 100, 0)}
        observed = groups(table, 10, 20, [30])
        self.assertEqual(observed["app_runtime"], {10, 11, 20})
        self.assertEqual(observed["agents"], {30, 31})
        self.assertEqual(observed["total"], {10, 11, 20, 30, 31})


if __name__ == "__main__":
    unittest.main()
