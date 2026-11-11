"""Production worker HTTP/2 on TCP and Unix listeners."""
from contextlib import ExitStack
import collections
import json
import pathlib
import os
import signal
import select
import socket
import subprocess
import sys
import tempfile
import time

from h2.settings import SettingCodes
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, ConnectionTerminated
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop


def verify(executable, unix, debug=False):
    with tempfile.TemporaryDirectory(prefix='roxum-h2-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'http.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\n')
        with tempfile.TemporaryFile(mode='w+') as errors, ExitStack() as sockets:
            process = subprocess.Popen([executable] + (["--debug"] if debug else []), cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timed out'
                endpoint = process.stdout.readline().strip()
                assert endpoint, 'startup failed'
                with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as sock:
                    sock.settimeout(10)
                    sock.connect(path if unix else ('127.0.0.1', int(endpoint)))
                    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
                    client.initiate_connection()
                    sock.sendall(client.data_to_send())
                    bodies = collections.defaultdict(bytes)
                    headers, ended, reset = {}, [], set()
                    raw_headers = {}

                    def request(stream, route='/echo', body=b'', method='POST', end=True):
                        client.send_headers(stream, [(':method', method), (':scheme', 'http'),
                                                     (':authority', 'localhost'), (':path', route)],
                                            end_stream=end and not body)
                        if body:
                            client.send_data(stream, body, end_stream=end)
                        sock.sendall(client.data_to_send())

                    def receive(wanted, rejected=frozenset()):
                        while not set(wanted).issubset(ended) or not set(rejected).issubset(reset):
                            wire = sock.recv(65536)
                            assert wire, (wanted, ended, reset)
                            for event in client.receive_data(wire):
                                assert not isinstance(event, ConnectionTerminated), event
                                if isinstance(event, ResponseReceived):
                                    headers[event.stream_id] = dict(event.headers)
                                    raw_headers[event.stream_id] = event.headers
                                elif isinstance(event, DataReceived):
                                    bodies[event.stream_id] += event.data
                                    client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                                elif isinstance(event, StreamEnded):
                                    ended.append(event.stream_id)
                                elif isinstance(event, StreamReset):
                                    reset.add(event.stream_id)
                            pending = client.data_to_send()
                            if pending:
                                sock.sendall(pending)

                    request(1, body=b'fragment-', end=False)
                    request(3, body=b'peer')
                    receive([3])
                    assert 1 not in ended
                    client.send_data(1, b'end', end_stream=True)
                    sock.sendall(client.data_to_send())
                    receive([1])
                    assert bodies[1] == b'42|h2|fragment-end'
                    assert bodies[3] == b'42|h2|peer'
                    # Repeat past the per-connection stream-slot capacity.
                    for stream in range(5, 45, 2):
                        request(stream, body=str(stream).encode())
                        receive([stream])
                        assert bodies[stream] == b'42|h2|' + str(stream).encode()
                    request(45, '/reject')
                    request(47, '/invalid-response')
                    request(49, '/missing')
                    request(51, body=b'head', method='HEAD')
                    receive([45, 49, 51], [47])
                    assert headers[45][':status'] == '422'
                    assert headers[49][':status'] == '404'
                    assert bodies[51] == b''
                    assert headers[51]['content-length'] == str(len(b'42|h2|head'))
                    request(53, '/sleep', b'detached')
                    request(55, body=b'other')
                    receive([53, 55])
                    assert bodies[53] == b'42|h2|detached'
                    assert bodies[55] == b'42|h2|other'
                    # Accepting the outbound connection proves the handler has
                    # acquired its permit. A competing probe before that point
                    # could acquire first and make the handler reject itself.
                    upstream = socket.socket()
                    upstream.settimeout(5)
                    upstream.bind(('127.0.0.1', 0))
                    upstream.listen()
                    try:
                        request(57, '/tcp-cancel', str(upstream.getsockname()[1]).encode())
                        borrowed, _ = upstream.accept()
                        sockets.enter_context(borrowed)
                    finally:
                        upstream.close()
                    borrowed.settimeout(5)
                    stream = 59
                    request(stream, '/permit')
                    receive([stream])
                    assert headers[stream][':status'] == '429'
                    client.reset_stream(57)
                    sock.sendall(client.data_to_send())
                    deadline = time.monotonic() + 5
                    while True:
                        stream += 2
                        request(stream, '/permit')
                        receive([stream])
                        if headers[stream][':status'] == '200':
                            break
                        assert time.monotonic() < deadline, 'reset did not release permit'
                    try:
                        assert borrowed.recv(1) == b'', 'reset did not close borrowed TCP'
                    finally:
                        borrowed.close()
                    # A reset must leave this connection usable after cleanup.
                    stream += 2
                    request(stream, body=b'after reset')
                    receive([stream])
                    assert bodies[stream] == b'42|h2|after reset'
                    # Malformed transport input on another connection must not
                    # kill this worker or disturb its existing connection.
                    with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as invalid:
                        invalid.settimeout(5)
                        invalid.connect(path if unix else ('127.0.0.1', int(endpoint)))
                        invalid.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                        while invalid.recv(65536):
                            pass
                    # EOF of a different HTTP/2 connection also closes its
                    # borrowed TCP resource, while this connection stays live.
                    with socket.socket() as upstream:
                        upstream.settimeout(5)
                        upstream.bind(('127.0.0.1', 0))
                        upstream.listen()
                        with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as abandoned:
                            abandoned.settimeout(5)
                            abandoned.connect(path if unix else ('127.0.0.1', int(endpoint)))
                            other = H2Connection()
                            other.initiate_connection()
                            other.send_headers(1, [(':method', 'POST'), (':scheme', 'http'),
                                (':authority', 'localhost'), (':path', '/tcp-cancel')])
                            other.send_data(1, str(upstream.getsockname()[1]).encode(), end_stream=True)
                            abandoned.sendall(other.data_to_send())
                            disconnected, _ = upstream.accept()
                            sockets.enter_context(disconnected)
                        disconnected.settimeout(5)
                        assert disconnected.recv(1) == b'', 'disconnect retained borrowed TCP'
                        disconnected.close()
                    # Configured finite body limit: nearest valid values and
                    # the first invalid size; a rejected stream leaves peers alive.
                    for size in (1023, 1024, 1025):
                        stream += 2
                        request(stream, body=b'x' * size)
                        if size <= 1024:
                            receive([stream])
                            assert bodies[stream] == b'42|h2|' + b'x' * size
                        else:
                            receive([], [stream])
                    # An unfinished body times out without preventing a peer.
                    stream += 2
                    partial = stream
                    request(partial, body=b'partial', end=False)
                    stream += 2
                    request(stream, body=b'while partial')
                    receive([stream], [partial])
                    assert bodies[stream] == b'42|h2|while partial'
                    # Incoming request IDs retain the existing host policy.
                    stream += 2
                    client.send_headers(stream, [(':method', 'GET'), (':scheme', 'http'),
                        (':authority', 'localhost'), (':path', '/id'), ('x-request-id', 'trusted-id')], end_stream=True)
                    sock.sendall(client.data_to_send())
                    receive([stream])
                    assert bodies[stream] == b'trusted-id'
                    for route, expected_count in (('/debug', 1), ('/debug-many', 16)):
                        stream += 2
                        request(stream, route)
                        receive([stream])
                        assert headers[stream][':status'] == '200'
                        values = [value for name, value in raw_headers[stream] if name == 'x-roxum-dbg']
                        assert len(values) == (expected_count if debug else 0), values
                        truncated = headers[stream].get('x-roxum-dbg-truncated')
                        assert truncated == ('5' if debug and route == '/debug-many' else None)
                    stream += 2
                    request(stream, '/crash')
                    receive([], [stream])
                    stream += 2
                    request(stream, body=b'after crash')
                    receive([stream])
                    assert bodies[stream] == b'42|h2|after crash'
                    # HEADERS without END_HEADERS must expire even before
                    # the first HPACK field arrives (empty header block).
                    with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as unfinished:
                        unfinished.settimeout(5)
                        unfinished.connect(path if unix else ('127.0.0.1', int(endpoint)))
                        partial_client = H2Connection()
                        partial_client.initiate_connection()
                        unfinished.sendall(partial_client.data_to_send() + bytes.fromhex('000000010000000001'))
                        while unfinished.recv(65536):
                            pass
                    # A stream with no receive credit expires independently;
                    # a bodyless peer still completes on that same connection.
                    with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as limited:
                        limited.settimeout(5)
                        limited.connect(path if unix else ('127.0.0.1', int(endpoint)))
                        slow = H2Connection()
                        slow.initiate_connection()
                        slow.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 0})
                        for sid, method in ((1, 'GET'), (3, 'HEAD')):
                            slow.send_headers(sid, [(':method', method), (':scheme', 'http'),
                                (':authority', 'localhost'), (':path', '/echo')], end_stream=True)
                        limited.sendall(slow.data_to_send())
                        peer_done = False
                        reset_seen = False
                        while not reset_seen:
                            wire = limited.recv(65536)
                            assert wire, 'flow-control timeout closed the connection'
                            for event in slow.receive_data(wire):
                                assert not isinstance(event, ConnectionTerminated)
                                if isinstance(event, StreamEnded) and event.stream_id == 3:
                                    peer_done = True
                                if isinstance(event, StreamReset) and event.stream_id == 1:
                                    assert peer_done, 'blocked stream prevented peer progress'
                                    reset_seen = True
                            pending = slow.data_to_send()
                            if pending:
                                limited.sendall(pending)
                    # Drain begins while a handler is waiting on upstream TCP.
                    # Strip GOAWAY before hyper-h2 decoding: its client state
                    # closes immediately, although lower streams may finish.
                    with socket.socket() as upstream:
                        upstream.settimeout(5)
                        upstream.bind(('127.0.0.1', 0))
                        upstream.listen()
                        stream += 2
                        request(stream, '/tcp', str(upstream.getsockname()[1]).encode())
                        drained, _ = upstream.accept()
                        sockets.enter_context(drained)
                    os.killpg(process.pid, signal.SIGTERM)
                    pending = b''
                    retained = b''
                    terminated = False
                    while True:
                        wire = sock.recv(65536)
                        if not wire:
                            break
                        pending += wire
                        while len(pending) >= 9:
                            length = int.from_bytes(pending[:3], 'big')
                            if len(pending) < 9 + length:
                                break
                            frame, pending = pending[:9 + length], pending[9 + length:]
                            if frame[3] == 7:
                                assert length >= 8
                                assert int.from_bytes(frame[9:13], 'big') & 0x7fffffff >= stream
                                assert int.from_bytes(frame[13:17], 'big') == 0
                                if not terminated:
                                    terminated = True
                                    drained.sendall(b'D')
                            else:
                                retained += frame
                    assert terminated and not pending, 'missing or truncated GOAWAY'
                    drain_events = client.receive_data(retained)
                    assert any(isinstance(event, StreamEnded) and event.stream_id == stream for event in drain_events)
                    assert b''.join(event.data for event in drain_events if isinstance(event, DataReceived) and event.stream_id == stream) == b'D'
                    drained.close()
                assert stop(process) == 0
                errors.seek(0)
                entries = [json.loads(line) for line in errors if line.startswith('{')]
                assert any(entry.get('request_id') == 'trusted-id' for entry in entries), entries
                for outcome in ('crashed', 'encode_failed', 'client_closed'):
                    assert any(entry.get('outcome') == outcome for entry in entries), (outcome, entries)
            except BaseException:
                stop(process)
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                process.stdout.close()
    print('PASS production HTTP/2 ' + ('Unix' if unix else 'TCP') + (' debug' if debug else ' normal'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)
    verify(executable, False, True)
    verify(executable, True, True)
