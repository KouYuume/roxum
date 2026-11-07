#!/usr/bin/env python3
import json
import statistics
import sys


def linear_slope_per_hour(samples):
    points = [
        (sample["elapsed_seconds"], sample["rss_kib"])
        for sample in samples
    ]
    if len(points) < 2:
        raise ValueError("soak result needs at least two resource samples")
    mean_x = statistics.mean(point[0] for point in points)
    mean_y = statistics.mean(point[1] for point in points)
    denominator = sum((x - mean_x) ** 2 for x, _ in points)
    if denominator == 0:
        raise ValueError("resource samples do not span time")
    kib_per_second = sum(
        (x - mean_x) * (y - mean_y) for x, y in points
    ) / denominator
    return kib_per_second * 3600 / 1024


def window_median(samples, first):
    edge = samples[0]["elapsed_seconds"] + 1800 if first else samples[-1]["elapsed_seconds"] - 1800
    window = [
        sample["rss_kib"]
        for sample in samples
        if (sample["elapsed_seconds"] <= edge) == first
    ]
    return statistics.median(window or [sample["rss_kib"] for sample in samples])


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: soak_check.py RESULT.json")
    data = json.load(open(sys.argv[1]))
    runs = data["architectures"].get("processes", {}).get("runs", [])
    if len(runs) != 1:
        raise SystemExit("expected exactly one process-pool soak run")
    run = runs[0]
    samples = run["resource_samples"]
    slope = linear_slope_per_hour(samples)
    window_growth_mib = (window_median(samples, False) - window_median(samples, True)) / 1024
    success_rate = run["oha"]["metrics"]["success_rate"]
    warm_fd = run["warm_baseline"]["fd_count"]
    post_fd = run["post_load"]["fd_count"]
    workers = run["warm_baseline"]["process_count"] - 1
    fd_limit = None if warm_fd is None else warm_fd + workers + 8
    checks = {
        "success_rate_is_one": success_rate == 1.0,
        "rss_slope_at_most_1_mib_per_hour": slope <= 1.0,
        "rss_window_growth_at_most_16_mib": window_growth_mib <= 16.0,
        "fd_returns_within_limit": fd_limit is None or post_fd <= fd_limit,
    }
    result = {
        "passed": all(checks.values()),
        "checks": checks,
        "observed": {
            "success_rate": success_rate,
            "rss_slope_mib_per_hour": slope,
            "rss_window_growth_mib": window_growth_mib,
            "warm_fd_count": warm_fd,
            "post_load_fd_count": post_fd,
            "fd_limit": fd_limit,
        },
    }
    print(json.dumps(result, indent=2))
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
