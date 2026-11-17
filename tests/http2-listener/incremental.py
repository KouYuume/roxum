"""Incremental reads on actual production Roc fibers, independent of request EOF."""
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
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset
from roxum_process import stop, ready_workers


def verify_incremental(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-h2-input-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'http.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\nbody_milliseconds = 5000\n')
        with tempfile.TemporaryFile(mode='w+') as errors:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
                endpoint = process.stdout.readline().strip()
                workers = ready_workers(process)
                with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as sock, socket.socket() as marker:
                    sock.settimeout(10)
                    sock.connect(path if unix else ('127.0.0.1', int(endpoint)))
                    marker.bind(('127.0.0.1', 0))
                    marker.listen()
                    marker.settimeout(5)
                    port = marker.getsockname()[1]
                    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
                    client.initiate_connection()
                    bodies, statuses, ended, reset = collections.defaultdict(bytes), {}, set(), set()
                    next_id = 1

                    def flush():
                        wire = client.data_to_send()
                        if wire:
                            sock.sendall(wire)

                    def receive(predicate):
                        deadline = time.monotonic() + 10
                        while not predicate():
                            sock.settimeout(max(.001, deadline - time.monotonic()))
                            wire = sock.recv(65536)
                            assert wire, 'unexpected EOF'
                            for event in client.receive_data(wire):
                                assert not isinstance(event, ConnectionTerminated), event
                                if isinstance(event, ResponseReceived):
                                    statuses[event.stream_id] = dict(event.headers)[':status']
                                elif isinstance(event, DataReceived):
                                    bodies[event.stream_id] += event.data
                                    client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                                elif isinstance(event, StreamEnded):
                                    ended.add(event.stream_id)
                                elif isinstance(event, StreamReset):
                                    reset.add(event.stream_id)
                            flush()
                            assert time.monotonic() < deadline, 'incremental progress timeout'

                    def request(route, payload=b'', end=False):
                        nonlocal next_id
                        sid = next_id
                        next_id += 2
                        client.send_headers(sid, [(':method', 'POST'), (':scheme', 'http'),
                                                 (':authority', 'localhost'), (':path', route)], end_stream=end and not payload)
                        if payload:
                            client.send_data(sid, payload, end_stream=end)
                        flush()
                        return sid

                    def observed_chunk():
                        with marker.accept()[0] as observed:
                            observed.settimeout(5)
                            data = b''
                            while len(data) < 5:
                                part = observed.recv(5 - len(data))
                                assert part, 'chunk marker truncated'
                                data += part
                            assert data == b'chunk'

                    flush()
                    # An effect from chunk!, before client EOF, is required progress.
                    sid = request(f'/input-count?{port}', b'a')
                    observed_chunk()
                    assert sid not in ended
                    # A bounded accumulator accepts a body far beyond the finite
                    # server cap (1024), using multiple replenished stream windows.
                    total = 256 * 1024 + 1
                    sent = 1
                    while sent < total:
                        receive(lambda: client.local_flow_control_window(sid) > 0)
                        count = min(16384, client.local_flow_control_window(sid), total - sent)
                        client.send_data(sid, b'x' * count, end_stream=sent + count == total)
                        sent += count
                        flush()
                    receive(lambda: sid in ended or sid in reset)
                    assert sid not in reset and statuses[sid] == '200'
                    assert bodies[sid] == str(total).encode()

                    # The route limit counts bytes already delivered to Roc,
                    # including the first byte beyond the cumulative boundary.
                    for size in (3, 4, 5):
                        limited = request(f'/input-limited?{port}', b'abc')
                        observed_chunk()
                        client.send_data(limited, b'de'[:size - 3], end_stream=size <= 4)
                        flush()
                        receive(lambda: limited in ended or limited in reset)
                        assert limited not in reset
                        assert statuses[limited] == ('413' if size == 5 else '200')
                        if size <= 4:
                            assert bodies[limited] == str(size).encode()
                        else:
                            client.reset_stream(limited)
                            flush()

                    # Reuse more than all 16 stream slots. The callback is asleep
                    # with unread queued input when reset arrives; a peer still runs.
                    for _ in range(18):
                        stalled = request(f'/input-wait?{port}', b'x')
                        observed_chunk()
                        remaining = client.local_flow_control_window(stalled)
                        client.send_data(stalled, b'q' * min(remaining, 16383))
                        peer = request('/echo', b'peer', end=True)
                        receive(lambda: peer in ended)
                        assert statuses[peer] == '200' and bodies[peer] == b'42|h2|peer'
                        assert stalled not in ended and stalled not in reset
                        client.reset_stream(stalled)
                        flush()
                    # Reset a reader parked waiting for its next chunk, too.
                    waiting = request(f'/input-count?{port}', b'x')
                    observed_chunk()
                    client.reset_stream(waiting)
                    peer = request('/echo', b'after', end=True)
                    receive(lambda: peer in ended)
                    assert bodies[peer] == b'42|h2|after'
                    assert ready_workers(process) == workers, 'worker restart hid input failure'
                assert stop(process) == 0
                errors.seek(0)
                diagnostic = errors.read()
                assert 'cancelled incremental input resumed' not in diagnostic and 'panic' not in diagnostic.lower(), diagnostic
                print('PASS incremental input before EOF, bounded accumulation, suspended cancellation and peer progress ' + ('Unix' if unix else 'TCP'))
            finally:
                stop(process)
                process.stdout.close()
