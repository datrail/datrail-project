"""Rates with confidence intervals clustered by task (design §4.5).

Repeated trials of one task are not independent, so a rate's standard error
is computed over task clusters (the CR1 sandwich, as *Adding Error Bars to
Evals* recommends), not over trials. With one cluster, or none, the interval
is the whole of [0, 1]: there is nothing to estimate a spread from.
"""
from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass
from typing import Hashable, Iterable

Z95 = 1.959963984540054


@dataclass(frozen=True)
class Rate:
    hits: int
    n: int
    clusters: int
    low: float
    high: float

    @property
    def value(self) -> float | None:
        return self.hits / self.n if self.n else None

    def as_dict(self) -> dict:
        return {"hits": self.hits, "n": self.n, "clusters": self.clusters,
                "rate": self.value, "ci95": [self.low, self.high]}


def clustered_rate(outcomes: Iterable[tuple[Hashable, bool]]) -> Rate:
    """`outcomes` is (cluster, success) per trial."""
    by_cluster: dict[Hashable, list[int]] = defaultdict(list)
    for cluster, ok in outcomes:
        by_cluster[cluster].append(1 if ok else 0)
    n = sum(len(v) for v in by_cluster.values())
    hits = sum(sum(v) for v in by_cluster.values())
    g = len(by_cluster)
    if n == 0:
        return Rate(0, 0, 0, 0.0, 1.0)
    p = hits / n
    if g < 2:
        return Rate(hits, n, g, 0.0, 1.0)
    # Sum of residuals per cluster, squared; CR1 small-sample factor g/(g-1).
    meat = sum(sum(y - p for y in ys) ** 2 for ys in by_cluster.values())
    se = math.sqrt(meat * g / (g - 1)) / n
    if se == 0.0:
        # Every trial the same: fall back to Wilson on the cluster count,
        # which never claims certainty from a handful of tasks.
        return Rate(hits, n, g, *wilson(round(p * g), g))
    return Rate(hits, n, g, max(0.0, p - Z95 * se), min(1.0, p + Z95 * se))


def wilson(hits: int, n: int) -> tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    p = hits / n
    denom = 1 + Z95 ** 2 / n
    centre = (p + Z95 ** 2 / (2 * n)) / denom
    half = Z95 * math.sqrt(p * (1 - p) / n + Z95 ** 2 / (4 * n * n)) / denom
    return max(0.0, centre - half), min(1.0, centre + half)


def paired_difference(pairs: Iterable[tuple[Hashable, float, float]]) -> dict:
    """Mean of b - a over tasks, each task's two arms averaged over its own
    trials first (`pairs` is (task, a, b) per task). Used for agent task
    success with datRail (b) against without it (a), §4.3 step 4."""
    diffs = [b - a for _, a, b in pairs]
    n = len(diffs)
    if n == 0:
        return {"tasks": 0, "mean": None, "ci95": None}
    mean = sum(diffs) / n
    if n < 2:
        return {"tasks": n, "mean": mean, "ci95": None}
    sd = math.sqrt(sum((d - mean) ** 2 for d in diffs) / (n - 1))
    half = Z95 * sd / math.sqrt(n)
    return {"tasks": n, "mean": mean, "ci95": [mean - half, mean + half]}
