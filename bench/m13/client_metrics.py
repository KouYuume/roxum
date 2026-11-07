"""Raw Linux generator counters; no automatic claim of sufficient headroom."""
from pathlib import Path
import threading
import time
import network_metrics


def snapshot(root=Path('/proc')):
    return {name: (root / name).read_text() for name in
            ('stat', 'loadavg', 'meminfo', 'net/dev', 'net/snmp', 'net/netstat')}


class ClientSampler:
    def __init__(self, interval=1):
        self.interval = interval
        self.samples = []
        self.errors = []
        self.network_before = None
        self.started_ns = None
        self.event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.network_before = network_metrics.snapshot()
        self.started_ns = time.monotonic_ns()
        self.thread.start()

    def _run(self):
        while not self.event.is_set():
            try:
                begin = time.monotonic_ns()
                counters = snapshot()
                self.samples.append({'seconds': (begin - self.started_ns) / 1e9,
                                     'begin_monotonic_ns': begin,
                                     'end_monotonic_ns': time.monotonic_ns(), 'counters': counters})
            except Exception as error:
                self.errors.append(f'{type(error).__name__}: {error}')
            self.event.wait(self.interval)

    def stop(self):
        self.event.set()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            self.errors.append('client sampler did not stop')
        return {'valid': len(self.samples) >= 2 and not self.errors,
                'clock': 'client_monotonic_ns', 'started_monotonic_ns': self.started_ns,
                'stopped_monotonic_ns': time.monotonic_ns(),
                'samples': self.samples, 'errors': self.errors,
                'interval_seconds': self.interval,
                'headroom_verified': False,
                'network_before': self.network_before,
                'network_after': network_metrics.snapshot() if self.network_before is not None else None}
