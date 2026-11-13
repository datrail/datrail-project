import unittest

from railbench.stats import clustered_rate, paired_difference, wilson


class ClusteredRate(unittest.TestCase):
    def test_empty_and_single_cluster_claim_nothing(self):
        self.assertEqual(clustered_rate([]).as_dict()["ci95"], [0.0, 1.0])
        one = clustered_rate([("t", True), ("t", True), ("t", False)])
        self.assertAlmostEqual(one.value, 2 / 3)
        self.assertEqual((one.low, one.high), (0.0, 1.0))

    def test_clustering_widens_the_interval(self):
        # Ten tasks, each all-or-nothing over 5 trials: trials are not
        # independent, so the interval must be wider than a naive one.
        outcomes = [(t, t < 5) for t in range(10) for _ in range(5)]
        rate = clustered_rate(outcomes)
        self.assertEqual(rate.value, 0.5)
        naive_low, naive_high = wilson(25, 50)
        self.assertLess(rate.low, naive_low)
        self.assertGreater(rate.high, naive_high)

    def test_all_same_falls_back_to_wilson_on_clusters(self):
        rate = clustered_rate([(t, True) for t in range(6)])
        self.assertEqual(rate.high, 1.0)
        self.assertLess(rate.low, 1.0)
        self.assertGreater(rate.low, 0.5)


class Paired(unittest.TestCase):
    def test_paired_difference(self):
        d = paired_difference([("a", 1.0, 1.0), ("b", 1.0, 0.0), ("c", 0.0, 0.0)])
        self.assertAlmostEqual(d["mean"], -1 / 3)
        self.assertEqual(d["tasks"], 3)
        self.assertLess(d["ci95"][0], d["mean"])


if __name__ == "__main__":
    unittest.main()
