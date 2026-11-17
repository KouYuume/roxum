"""Independent duplex progress with bounded input/output and real Roc callbacks."""
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
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived
from h2.settings import SettingCodes
from roxum_process import ready_workers, stop


def verify_duplex(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-h2-duplex-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'http.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) +
                                         '\nbody_milliseconds = 10000\nwrite_milliseconds = 10000\n')
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
                    bodies, headers, trailers = collections.defaultdict(bytes), {}, {}
                    ended, resets = set(), set()
                    withheld = collections.Counter()
                    next_id = 1

                    def flush():
                        wire = client.data_to_send()
                        if wire:
                            sock.sendall(wire)

                    def request(route='/duplex', end=False):
                        nonlocal next_id
                        sid = next_id
                        next_id += 2
                        client.send_headers(sid, [(':method', 'POST'), (':scheme', 'http'),
                                                 (':authority', 'localhost'), (':path', route),
                                                 ('x-request-id', f'duplex-{sid}')], end_stream=end)
                        flush()
                        return sid

                    def receive(until, hold=None):
                        deadline = time.monotonic() + 10
                        while not until():
                            assert time.monotonic() < deadline, 'duplex progress timeout'
                            wire = sock.recv(65536)
                            assert wire, 'connection closed'
                            for event in client.receive_data(wire):
                                if isinstance(event, DataReceived):
                                    bodies[event.stream_id] += event.data
                                    if event.stream_id == hold:
                                        withheld[event.stream_id] += event.flow_controlled_length
                                    else:
                                        client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                                elif isinstance(event, ResponseReceived):
                                    headers[event.stream_id] = dict(event.headers)
                                elif isinstance(event, TrailersReceived):
                                    trailers[event.stream_id] = dict(event.headers)
                                elif isinstance(event, StreamEnded):
                                    ended.add(event.stream_id)
                                elif isinstance(event, StreamReset):
                                    resets.add(event.stream_id)
                            flush()

                    flush()
                    # Empty input, one chunk boundary, and a transfer larger than
                    # the initial connection window. The last case requires read
                    # wakes while output cannot accept its next chunk.
                    for length in (0, 16383, 16384, 16385, 131072):
                        sid = request(end=length == 0)
                        receive(lambda: len(bodies[sid]) == 1024, hold=sid)
                        assert headers[sid]['x-duplex'] == 'checked'
                        assert sid not in ended and sid not in resets
                        sent = 0
                        while sent < length:
                            receive(lambda: client.local_flow_control_window(sid) > 0, hold=sid)
                            count = min(length - sent, client.local_flow_control_window(sid),
                                        client.max_outbound_frame_size)
                            sent += count
                            client.send_data(sid, b'a' * count, end_stream=sent == length)
                            flush()
                        peer = request('/echo', end=True)
                        receive(lambda: peer in ended, hold=sid)
                        assert headers[peer][':status'] == '200'
                        assert sid not in ended and sid not in resets
                        client.acknowledge_received_data(withheld.pop(sid), sid)
                        flush()
                        receive(lambda: sid in ended)
                        assert bodies[sid] == b'x' * 32768
                        assert trailers[sid]['x-received'] == str(length)
                        assert sid not in resets
                        # Wait for cleanup, not merely terminal frame arrival.
                        deadline = time.monotonic() + 3
                        while True:
                            peer = request('/permit', end=True)
                            receive(lambda: peer in ended)
                            if headers[peer][':status'] == '200':
                                break
                            assert headers[peer][':status'] == '429' and time.monotonic() < deadline
                    # Reset with both interests registered must release the permit
                    # and permit a new request on the same worker and connection.
                    sid = request()
                    receive(lambda: len(bodies[sid]) == 1024, hold=sid)
                    client.reset_stream(sid)
                    flush()
                    deadline = time.monotonic() + 3
                    while True:
                        peer = request('/permit', end=True)
                        receive(lambda: peer in ended)
                        if headers[peer][':status'] == '200':
                            break
                        assert time.monotonic() < deadline
                    # Checks rejecting chunks or EOF must reset, never publish a
                    # successful empty terminal. A body-limit failure is delivered
                    # to the callback, which can choose its own terminal fields.
                    for route, payload, rejected in (
                        ('/duplex-reject', b'a', True),
                        ('/duplex-reject-end', b'', True),
                        ('/duplex-limit', b'AAA', False),
                        ('/duplex-limit', b'AAAA', False),
                        ('/duplex-limit', b'aaaaa', False),
                    ):
                        sid = request(route)
                        receive(lambda: len(bodies[sid]) == 1024, hold=sid)
                        client.send_data(sid, payload, end_stream=True)
                        flush()
                        if rejected:
                            receive(lambda: sid in resets, hold=sid)
                            assert sid not in ended and sid not in trailers
                        else:
                            client.acknowledge_received_data(withheld.pop(sid), sid)
                            flush()
                            receive(lambda: sid in ended)
                            if len(payload) > 4:
                                assert trailers[sid]['x-result'] == 'input-failed'
                            else:
                                assert trailers[sid]['x-received'] == str(len(payload))
                        deadline = time.monotonic() + 3
                        while True:
                            peer = request('/permit', end=True)
                            receive(lambda: peer in ended)
                            if headers[peer][':status'] == '200':
                                break
                            assert time.monotonic() < deadline
                    assert ready_workers(process) == workers, 'worker restart hid failure'
                assert stop(process) == 0
                errors.seek(0)
                diagnostic = errors.read()
                assert 'panic' not in diagnostic.lower() and 'crash' not in diagnostic.lower(), diagnostic
                print('PASS duplex independent input/output, middleware, boundaries and cancellation ' +
                      ('Unix' if unix else 'TCP'))
            finally:
                stop(process)
                process.stdout.close()


def verify_duplex_http1(executable):
    import http.client

    with tempfile.TemporaryDirectory(prefix='roxum-duplex-http1-', dir='/tmp') as directory:
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('http1 = true\n')
        with tempfile.TemporaryFile(mode='w+') as errors:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
                endpoint = int(process.stdout.readline().strip())
                client = http.client.HTTPConnection('127.0.0.1', endpoint, timeout=5)
                try:
                    client.request('POST', '/duplex', b'a')
                    response = client.getresponse()
                    assert response.status == 501
                    response.read()
                finally:
                    client.close()
                assert stop(process) == 0
                errors.seek(0)
                diagnostic = errors.read()
                assert 'crash' not in diagnostic.lower() and 'panic' not in diagnostic.lower(), diagnostic
                print('PASS duplex HTTP/1 unsupported response')
            finally:
                stop(process)
                process.stdout.close()
