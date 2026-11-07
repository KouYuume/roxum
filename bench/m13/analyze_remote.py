#!/usr/bin/env python3
"""Summarize remote diagnostics without certifying comparative validity."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import network_metrics


def cpu_counters(text):
    # guest time is already included in user/nice; count only the first eight fields.
    return {parts[0]: [int(value) for value in parts[1:9]]
            for line in text.splitlines() if (parts := line.split()) and parts[0].startswith('cpu')}


def network_counters(text):
    return {name.strip(): [int(value) for value in values.split()]
            for line in text.splitlines() if ':' in line for name, values in [line.split(':', 1)]}


def tcp_counters(text):
    lines = text.splitlines()
    for header, values in zip(lines, lines[1:]):
        if header.startswith('Tcp:') and values.startswith('Tcp:'):
            return dict(zip(header.split()[1:], map(int, values.split()[1:])))
    raise ValueError('TCP counters missing')


def delta(before, after):
    if len(before) != len(after):
        raise ValueError('counter shape changed')
    result = [end - start for start, end in zip(before, after)]
    if any(value < 0 for value in result):
        raise ValueError('counter decreased; reset or discontinuity')
    return result


def telemetry(metrics):
    samples = metrics.get('samples', [])
    if not metrics.get('valid') or len(samples) < 2:
        raise ValueError('at least two valid telemetry samples required')
    cpu_intervals, network_intervals, retransmissions = [], [], 0
    for before, after in zip(samples, samples[1:]):
        duration = after['seconds'] - before['seconds']
        if not math.isfinite(duration) or duration <= 0:
            raise ValueError('sample timestamps must increase')
        first, last = before['counters'], after['counters']
        cpus_a, cpus_b = cpu_counters(first['stat']), cpu_counters(last['stat'])
        if cpus_a.keys() != cpus_b.keys() or 'cpu' not in cpus_a:
            raise ValueError('CPU topology changed or missing')
        usage = {}
        for cpu in cpus_a:
            values = delta(cpus_a[cpu], cpus_b[cpu])
            total = sum(values)
            if len(values) != 8 or total <= 0:
                raise ValueError('invalid CPU accounting interval')
            usage[cpu] = {'busy_percent': 100 * (total - values[3] - values[4] - values[7]) / total,
                          'steal_percent': 100 * values[7] / total}
        cpu_intervals.append(usage)
        net_a, net_b = network_counters(first['net/dev']), network_counters(last['net/dev'])
        if net_a.keys() != net_b.keys():
            raise ValueError('network interfaces changed')
        interfaces = {}
        for name in net_a:
            values = delta(net_a[name], net_b[name])
            if len(values) != 16:
                raise ValueError('invalid interface counters')
            interfaces[name] = {'rx_bps': values[0] * 8 / duration,
                                'tx_bps': values[8] * 8 / duration,
                                'rx_errors': values[2], 'rx_drops': values[3],
                                'tx_errors': values[10], 'tx_drops': values[11]}
        network_intervals.append(interfaces)
        retransmissions += delta([tcp_counters(first['net/snmp'])['RetransSegs']],
                                 [tcp_counters(last['net/snmp'])['RetransSegs']])[0]
    return {'cpu_intervals': cpu_intervals, 'network_intervals': network_intervals,
            'tcp_retransmissions': retransmissions, 'headroom_verified': False}


def summarize(data):
    rows = data['samples']
    accepted = bool(rows) and data.get('comparison_valid') is True and all(r.get('valid') for r in rows)
    result = {'kind': data['kind'], 'all_trials_accepted': accepted,
              'headroom_verified': False, 'trials': [], 'throughput': {}}
    for row in rows:
        entry = {key: row.get(key) for key in ('server', 'scenario', 'repetition', 'valid',
                                              'exception', 'invalid_reasons', 'p50_ms', 'p99_ms', 'max_ms')}
        try:
            entry['telemetry'] = telemetry(row.get('client_metrics', {}))
        except (KeyError, ValueError, TypeError) as error:
            entry['telemetry_error'] = str(error)
        for host, before, after in (
            ('client', row.get('client_metrics', {}).get('network_before'),
             row.get('client_metrics', {}).get('network_after')),
            ('server', row.get('before', {}).get('network_limits'),
             row.get('after', {}).get('network_limits')),
        ):
            try:
                entry[host + '_network_limit_events'] = network_metrics.changes(before or {}, after or {})
            except (KeyError, ValueError, TypeError) as error:
                entry[host + '_network_limit_error'] = str(error)
        result['trials'].append(entry)
    # A failed experiment cannot acquire a favorable summary by dropping failed trials.
    if accepted:
        for scenario in sorted({r['scenario'] for r in rows}):
            result['throughput'][scenario] = {}
            for name in sorted({r['server'] for r in rows}):
                values = [r['rps'] for r in rows if r['scenario'] == scenario and r['server'] == name]
                if values:
                    result['throughput'][scenario][name] = {
                        'repetitions': values, 'median': statistics.median(values),
                        'minimum': min(values), 'maximum': max(values)}
    return result


def aa_control(data, labels):
    if len(set(labels)) != 2:
        raise ValueError('A/A requires two distinct labels')
    if not data.get('comparison_valid') or not all(row.get('valid') for row in data['samples']):
        raise ValueError('A/A requires an accepted experiment')
    rows = [row for row in data['samples'] if row['server'] in labels]
    hashes = {row['start']['binary']['sha256'] for row in rows}
    configs = {json.dumps(row['start']['config'], sort_keys=True) for row in rows}
    if len(hashes) != 1 or len(configs) != 1:
        raise ValueError('A/A binaries and service configurations must be identical')
    result = {}
    for scenario in sorted({row['scenario'] for row in rows}):
        groups = [[row for row in rows if row['scenario'] == scenario and row['server'] == name]
                  for name in labels]
        repetitions = [sorted(row['repetition'] for row in group) for group in groups]
        if not groups[0] or repetitions[0] != repetitions[1] or len(set(repetitions[0])) != len(groups[0]):
            raise ValueError('A/A labels must have matching unique repetitions')
        values = [[row['rps'] for row in group] for group in groups]
        medians = [statistics.median(group) for group in values]
        result[scenario] = {
            'labels': labels, 'binary_sha256': next(iter(hashes)),
            'repetitions_per_label': len(groups[0]),
            'median_difference_percent': 100 * (medians[1] / medians[0] - 1),
            'ranges': [[min(group), max(group)] for group in values],
            'interpretation': 'Observed control variation, not a significance test or fairness certification.'}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--aa', nargs=2, metavar=('BASELINE', 'CONTROL'))
    args = parser.parse_args()
    data = json.loads(args.input.read_text())
    result = summarize(data)
    result['input_sha256'] = hashlib.sha256(args.input.read_bytes()).hexdigest()
    result['analysis_sources'] = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (Path(__file__), Path(network_metrics.__file__))}
    if args.aa:
        result['aa_control'] = aa_control(data, args.aa)
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
