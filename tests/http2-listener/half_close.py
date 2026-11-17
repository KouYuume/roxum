"""Streamed response completion before and after request EOF on production fibers."""
import collections
import json
import pathlib
import select
import socket
import subprocess
import tempfile
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived
from h2.settings import SettingCodes
from roxum_process import ready_workers, stop


def verify_half_close(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-h2-half-close-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'http.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\nbody_milliseconds = 5000\nwrite_milliseconds = 5000\n')
        with tempfile.TemporaryFile(mode='w+') as errors:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
                endpoint = process.stdout.readline().strip()
                workers = ready_workers(process)
                with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as sock:
                    sock.settimeout(10)
                    sock.connect(path if unix else ('127.0.0.1', int(endpoint)))
                    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
                    client.initiate_connection()
                    client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 1024})
                    bodies, statuses, trailers = collections.defaultdict(bytes), {}, {}
                    ended, resets = set(), collections.Counter()
                    withheld = collections.Counter()
                    next_id = 1

                    def flush():
                        wire = client.data_to_send()
                        if wire:
                            sock.sendall(wire)

                    def receive(predicate, hold=None):
                        deadline = time.monotonic() + 10
                        while not predicate():
                            sock.settimeout(max(.001, deadline - time.monotonic()))
                            wire = sock.recv(65536)
                            assert wire, 'unexpected EOF'
                            for event in client.receive_data(wire):
                                assert not isinstance(event, ConnectionTerminated), event
                                sid = getattr(event, 'stream_id', 0)
                                if isinstance(event, ResponseReceived):
                                    statuses[sid] = dict(event.headers)[':status']
                                elif isinstance(event, TrailersReceived):
                                    trailers[sid] = dict(event.headers)
                                elif isinstance(event, DataReceived):
                                    bodies[sid] += event.data
                                    if sid == hold:
                                        withheld[sid] += event.flow_controlled_length
                                    else:
                                        client.acknowledge_received_data(event.flow_controlled_length, sid)
                                elif isinstance(event, StreamEnded):
                                    ended.add(sid)
                                elif isinstance(event, StreamReset):
                                    assert sid in ended, 'reset preceded response END_STREAM'
                                    assert event.error_code == 0, event
                                    resets[sid] += 1
                            flush()
                            assert time.monotonic() < deadline, 'half-close timeout'

                    def request(route, end=True):
                        nonlocal next_id
                        sid = next_id
                        next_id += 2
                        client.send_headers(sid, [(':method', 'POST'), (':scheme', 'http'),
                                                 (':authority', 'localhost'), (':path', route),
                                                 ('x-request-id', f'half-close-{sid}')])
                        client.send_data(sid, b'q', end_stream=end)
                        flush()
                        return sid

                    cases = [('explicit', False), ('implicit', False), ('empty', False),
                             ('expiry', False), ('explicit', True)] * 4
                    expected_logs = {}
                    flush()
                    for mode, input_ended in cases:
                        sid = request('/half-close?' + mode, end=input_ended)
                        expected_logs[sid] = 'timeout' if mode == 'expiry' else 'handled'
                        if mode in ('explicit', 'implicit'):
                            # Exhaust output credit while input remains independent.
                            receive(lambda: len(bodies[sid]) == 1024, hold=sid)
                            peer = request('/echo')
                            receive(lambda: peer in ended, hold=sid)
                            assert statuses[peer] == '200' and bodies[peer] == b'42|h2|q'
                            assert sid not in ended and resets[sid] == 0
                            client.acknowledge_received_data(withheld.pop(sid), sid)
                            flush()
                        receive(lambda: sid in ended and (input_ended or resets[sid] == 1))
                        assert statuses[sid] == '200'
                        expected = b'' if mode == 'empty' else b'first' if mode == 'expiry' else b'first' + b'x' * 32768
                        assert bodies[sid] == expected
                        if mode != 'implicit':
                            assert trailers[sid]['x-result'] == ('expired' if mode == 'expiry' else 'done')
                        # A completed writer must release its native permit even
                        # when callback code attempts another wait after finish.
                        deadline = time.monotonic() + 3
                        while True:
                            peer = request('/permit')
                            receive(lambda: peer in ended)
                            if statuses[peer] == '200':
                                break
                            assert statuses[peer] == '429' and time.monotonic() < deadline, 'completion retained permit'
                        assert resets[sid] == (0 if input_ended else 1)
                    assert ready_workers(process) == workers, 'worker restart hid a failure'
                assert stop(process) == 0
                errors.seek(0)
                diagnostic = errors.read()
                assert 'half-close completion resumed' not in diagnostic and 'half-close expiry resumed' not in diagnostic
                assert 'panic' not in diagnostic.lower(), diagnostic
                entries = [json.loads(line) for line in diagnostic.splitlines() if line.startswith('{')]
                for sid, outcome in expected_logs.items():
                    matches = [entry for entry in entries if entry.get('request_id') == f'half-close-{sid}']
                    assert len(matches) == 1 and matches[0]['outcome'] == outcome, matches
                    assert matches[0]['status'] == 200 and matches[0]['route'] == '/half-close', matches
                print('PASS half-close ordering, blocked output, expiry, permit cleanup and slot reuse ' + ('Unix' if unix else 'TCP'))
            finally:
                stop(process)
                process.stdout.close()
