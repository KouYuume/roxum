#!/usr/bin/env python3
import json
import statistics
import sys


def architecture_summary(data):
    output = {}
    for architecture, value in data["architectures"].items():
        runs = value["runs"]
        output[architecture] = {
            "median_requests_per_second": statistics.median(
                run["oha"]["metrics"]["requests_per_sec"] for run in runs
            ),
            "median_p99_milliseconds": statistics.median(
                run["oha"]["metrics"]["latency_ms"]["p99"] for run in runs
            ),
            "minimum_success_rate": min(
                run["oha"]["metrics"]["success_rate"] for run in runs
            ),
            "peak_rss_kib": max(
                sample["rss_kib"]
                for run in runs
                for sample in run["resource_samples"]
            ),
        }
    return output


def main():
    saturation = json.load(open(sys.argv[1]))
    fixed = json.load(open(sys.argv[2]))
    saturation_summary = architecture_summary(saturation)
    fixed_summary = architecture_summary(fixed)
    threads = saturation_summary["threads"]
    processes = saturation_summary["processes"]
    fixed_threads = fixed_summary["threads"]
    fixed_processes = fixed_summary["processes"]
    choose_threads = (
        threads["minimum_success_rate"] == 1.0
        and processes["minimum_success_rate"] == 1.0
        and fixed_threads["minimum_success_rate"] == 1.0
        and fixed_processes["minimum_success_rate"] == 1.0
        and threads["median_requests_per_second"]
        >= processes["median_requests_per_second"] * 0.95
        and fixed_threads["median_p99_milliseconds"]
        <= fixed_processes["median_p99_milliseconds"] * 1.05
    )
    result = {
        "saturation": saturation_summary,
        "fixed_20000_qps": fixed_summary,
        "selection": "threads" if choose_threads else "processes",
        "criteria": {
            "threads_minimum_relative_rps": 0.95,
            "threads_maximum_relative_fixed_rate_p99": 1.05,
            "success_rate": 1.0,
        },
    }
    with open(sys.argv[3], "w") as output:
        json.dump(result, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
