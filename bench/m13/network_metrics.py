"""Optional ENA counters, preserved separately from HTTP trial acceptance."""
from pathlib import Path
import subprocess

REQUIRED = ('bw_in_allowance_exceeded', 'bw_out_allowance_exceeded',
            'pps_allowance_exceeded', 'conntrack_allowance_exceeded',
            'linklocal_allowance_exceeded')


def parse_ena(text):
    counters = {}
    for line in text.splitlines():
        name, separator, value = line.strip().partition(':')
        if separator and name in REQUIRED:
            counters[name] = int(value.strip())
    if set(counters) != set(REQUIRED) or any(value < 0 for value in counters.values()):
        raise ValueError('missing or invalid ENA allowance counters')
    return counters


def snapshot(root=Path('/sys/class/net')):
    interfaces, errors = {}, []
    try:
        devices = sorted(root.iterdir())
    except OSError as error:
        return {'valid': False, 'interfaces': {}, 'errors': [str(error)]}
    for device in devices:
        if device.name == 'lo':
            continue
        argv = ['ethtool', '-S', device.name]
        record = {'command': argv}
        try:
            completed = subprocess.run(argv, capture_output=True, text=True, timeout=5)
            record.update(stdout=completed.stdout, stderr=completed.stderr, exit_code=completed.returncode)
            if completed.returncode:
                raise ValueError('ethtool failed')
            record['counters'] = parse_ena(completed.stdout)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            record['error'] = str(error)
            errors.append(f'{device.name}: {error}')
        interfaces[device.name] = record
    return {'valid': bool(interfaces) and not errors, 'interfaces': interfaces, 'errors': errors}


def changes(before, after):
    if not before.get('valid') or not after.get('valid'):
        raise ValueError('ENA counters unavailable')
    left, right = before['interfaces'], after['interfaces']
    if not left or left.keys() != right.keys():
        raise ValueError('network interfaces changed or missing')
    result = {}
    for interface in left:
        start, end = left[interface]['counters'], right[interface]['counters']
        values = {name: end[name] - start[name] for name in REQUIRED}
        if any(value < 0 for value in values.values()):
            raise ValueError('ENA counter decreased; driver reset or discontinuity')
        result[interface] = values
    return result
