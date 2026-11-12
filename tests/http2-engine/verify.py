#!/usr/bin/env python3
"""Independent wire checks for the internal engine's finite-response contract."""
import argparse
import os
from collections import defaultdict
import select
import socket
import subprocess
import struct
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, ConnectionTerminated
from h2.settings import SettingCodes
from h2.events import PingAckReceived, SettingsAcknowledged, TrailersReceived
from h2.errors import ErrorCodes
from hyperframe.frame import HeadersFrame


def verify(executable):
    process = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    sock = None
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'startup timeout'
        port = int(process.stdout.readline())
        sock = socket.create_connection(('127.0.0.1', port), timeout=5)
        conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        conn.initiate_connection()
        conn.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 16})
        body, status, ended, reset = defaultdict(bytes), {}, set(), set()
        response_fields = {}

        def flush():
            sock.sendall(conn.data_to_send())

        def until(predicate):
            deadline = time.monotonic() + 5
            while not predicate():
                sock.settimeout(max(.001, deadline - time.monotonic()))
                data = sock.recv(65536)
                assert data, 'unexpected EOF'
                for event in conn.receive_data(data):
                    if isinstance(event, DataReceived):
                        body[event.stream_id] += event.data
                        if event.flow_controlled_length:
                            conn.increment_flow_control_window(event.flow_controlled_length)
                    elif isinstance(event, ResponseReceived):
                        response_fields[event.stream_id] = dict(event.headers)
                        status[event.stream_id] = response_fields[event.stream_id][':status']
                    elif isinstance(event, StreamEnded):
                        ended.add(event.stream_id)
                    elif isinstance(event, StreamReset):
                        reset.add(event.stream_id)
                    elif isinstance(event, ConnectionTerminated):
                        raise AssertionError(f'unexpected GOAWAY: {event}')
                flush()
                assert time.monotonic() < deadline, 'progress timeout'

        def request(stream, payload=b'', extra=(), end=True, method='POST', path='/'):
            conn.send_headers(stream, [(':method', method), (':scheme', 'http'),
                                      (':authority', 'localhost'), (':path', path), *extra], end_stream=end and not payload)
            if payload:
                conn.send_data(stream, payload, end_stream=end)
            flush()

        def completed(stream, expected):
            until(lambda: stream in ended or stream in reset)
            assert stream not in reset, f'unexpected reset {stream}'
            assert status[stream] == '200'
            assert body[stream] == expected, (stream, len(body[stream]), len(expected))

        flush()
        # One unfinished request cannot prevent another response or survive reset.
        request(1, end=False)
        request(3, b'alive')
        completed(3, b'alive')
        conn.reset_stream(1, error_code=8)
        flush()
        request(5, b'next')
        completed(5, b'next')

        # No additional credit below/at the window, exactly one byte above it.
        for stream, size in [(7, 15), (9, 16), (11, 17)]:
            payload = bytes(range(size))
            request(stream, payload)
            if size == 17:
                until(lambda: len(body[stream]) == 16)
                assert stream not in ended
                request(13, b'free')
                completed(13, b'free')
                conn.increment_flow_control_window(1, stream_id=stream)
                flush()
            completed(stream, payload)

        # Input body cap: nearest valid sizes and first rejected size.
        for stream, size in [(15, 4095), (17, 4096), (19, 4097)]:
            payload = bytes(i % 251 for i in range(size))
            request(stream, payload)
            if size == 4097:
                until(lambda: stream in reset)
                assert stream not in ended
            else:
                conn.increment_flow_control_window(8192, stream_id=stream)
                flush()
                completed(stream, payload)

        # RFC header-list accounting: base 175 + x-bound(7) + overhead32 + value.
        for stream, value_size in [(21, 809), (23, 810), (25, 811)]:
            request(stream, extra=[('x-bound', 'a' * value_size)])
            if value_size == 811:
                until(lambda: stream in reset)
            else:
                completed(stream, b'')
        request(27, b'after limits')
        completed(27, b'after limits')

        # Fill every admitted slot, then finish all on the same connection.
        for stream in range(29, 61, 2):
            request(stream, end=False)
        for stream in range(29, 61, 2):
            conn.end_stream(stream)
        flush()
        for stream in range(29, 61, 2):
            completed(stream, b'')

        request(61, b'head representation', method='HEAD')
        completed(61, b'')

        # Reject before the first observer header, more times than lease capacity.
        # Closure must not create a request lease for an unobserved stream.
        for stream in range(63, 97, 2):
            request(stream, method='A' * 1100)
            until(lambda: stream in reset)
        request(97, b'after reject')
        completed(97, b'after reject')

        # Input survives callback batches; trailers never enter initial metadata.
        conn.send_headers(99, [(':method', 'POST'), (':scheme', 'http'),
                               (':authority', 'localhost'), (':path', '/owned?x=%2F'),
                               ('x-repeat', 'first'), ('x-repeat', 'second')])
        conn.send_data(99, b'part-')
        flush()
        conn.send_data(99, b'two')
        conn.send_headers(99, [('x-trailer', 'discarded')], end_stream=True)
        flush()
        completed(99, b'part-two')
        assert response_fields[99]['x-request-path'] == '/owned?x=%2F'
        assert response_fields[99]['x-initial-fields'] == '3'

        # Initial header accounting is 174 + path length. A valid long path
        # must not overflow the fixture's diagnostic response headers.
        for stream, path_length in [(101, 849), (103, 850), (105, 851)]:
            path = '/' + 'a' * (path_length - 1)
            request(stream, path=path)
            if path_length == 851:
                until(lambda: stream in reset)
            else:
                completed(stream, b'')
                assert response_fields[stream]['x-request-path'] == path[:64]
                assert response_fields[stream]['x-request-path-length'] == str(path_length)
        request(107, b'after long path')
        completed(107, b'after long path')

        # Engine-valid metadata rejected by the Roc request contract stays local.
        request(109, method='TRACE')
        until(lambda: 109 in reset)
        request(111, path='/invalid//segment')
        until(lambda: 111 in reset)
        request(113, b'after rejection')
        completed(113, b'after rejection')

        # Metadata installs the execution budget before body EOF. The peer
        # remains usable while an unfinished request expires without a response.
        request(115, b'partial', end=False, path='/deadline')
        request(117, b'peer')
        completed(117, b'peer')
        until(lambda: 115 in reset)
        assert 115 not in status
        request(119, b'after deadline')
        completed(119, b'after deadline')

        # Disconnect with engine-owned response bytes still flow controlled.
        request(121, b'x' * 4096)
        until(lambda: len(body[121]) == 16)
        sock.close()
        sock = None
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        print('PASS multiplexing/reset, partial output, owned responses, 15/16/17 output, '
              'body/header bounds, metadata deadline, 16 admitted streams, disconnect cleanup')
        print(stderr.strip())
    finally:
        if sock is not None:
            sock.close()
        if process.poll() is None:
            process.kill()
        process.wait()


def verify_header_budget(executable):
    """A budget that cannot retain any header resets streams, not the connection."""
    process = subprocess.Popen([executable], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True,
                               env=dict(os.environ, ROXUM_TEST_HTTP2_INPUT_BUDGET='0'))
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'startup timeout'
        with socket.create_connection(('127.0.0.1', int(process.stdout.readline())), timeout=5) as sock:
            conn = H2Connection(config=H2Configuration(client_side=True))
            conn.initiate_connection()
            # Sequential attempts also prove rejected lease slots are reusable.
            for stream in range(1, 39, 2):
                conn.send_headers(stream, [(':method', 'POST'), (':scheme', 'http'),
                                           (':authority', 'localhost'), (':path', '/')], end_stream=True)
                probe = stream.to_bytes(8, 'big')
                conn.ping(probe)
                sock.sendall(conn.data_to_send())
                reset, ack = False, False
                deadline = time.monotonic() + 5
                while not (reset and ack):
                    sock.settimeout(max(.001, deadline - time.monotonic()))
                    wire = sock.recv(65536)
                    assert wire, 'header budget rejection closed connection'
                    for event in conn.receive_data(wire):
                        assert not isinstance(event, (ResponseReceived, ConnectionTerminated)), event
                        if isinstance(event, StreamReset):
                            assert event.stream_id == stream
                            reset = True
                        if isinstance(event, PingAckReceived):
                            assert event.ping_data == probe
                            ack = True
                    pending = conn.data_to_send()
                    if pending: sock.sendall(pending)
                    assert time.monotonic() < deadline, 'header rejection progress timeout'
        _, errors = process.communicate(timeout=10)
        assert process.returncode == 0, errors
        print('PASS header budget rejection, repeated stream reset and connection liveness')
    finally:
        if process.poll() is None: process.kill()
        process.wait()


def verify_input_budget(executable):
    """Input budget failure resets one stream and releases capacity for reuse."""
    env = dict(os.environ, ROXUM_TEST_HTTP2_INPUT_BUDGET='2048')
    process = subprocess.Popen([executable], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env)
    sock = None
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'startup timeout'
        sock = socket.create_connection(('127.0.0.1', int(process.stdout.readline())), timeout=5)
        conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        conn.initiate_connection()
        bodies, ended, reset = defaultdict(bytes), set(), set()

        def flush():
            sock.sendall(conn.data_to_send())

        def until(predicate):
            deadline = time.monotonic() + 5
            while not predicate():
                sock.settimeout(max(.001, deadline - time.monotonic()))
                data = sock.recv(65536)
                assert data, 'unexpected EOF after input budget rejection'
                for event in conn.receive_data(data):
                    if isinstance(event, DataReceived):
                        bodies[event.stream_id] += event.data
                        conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, StreamEnded):
                        ended.add(event.stream_id)
                    elif isinstance(event, StreamReset):
                        reset.add(event.stream_id)
                    elif isinstance(event, ConnectionTerminated):
                        raise AssertionError(f'input rejection closed connection: {event}')
                flush()
                assert time.monotonic() < deadline, 'input budget progress timeout'

        def start(stream):
            conn.send_headers(stream, [(':method', 'POST'), (':scheme', 'http'),
                                       (':authority', 'localhost'), (':path', '/')])

        start(1)
        conn.send_data(1, b'held')
        start(3)
        # Below the engine's 4096-byte body cap, but above the shared input budget.
        conn.send_data(3, b'x' * 2048, end_stream=True)
        flush()
        until(lambda: 3 in reset)
        assert 1 not in reset
        conn.end_stream(1)
        flush()
        until(lambda: 1 in ended)
        assert bodies[1] == b'held'
        # Repeated rejection cannot consume the budget or the lease slots.
        for stream in range(5, 39, 2):
            start(stream)
            conn.send_data(stream, b'x' * 2048, end_stream=True)
            flush()
            until(lambda: stream in reset)
        start(39)
        conn.send_data(39, b'reused', end_stream=True)
        flush()
        until(lambda: 39 in ended)
        assert bodies[39] == b'reused'
        sock.close()
        sock = None
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        print('PASS input budget rejection, unrelated stream progress, repeated reset and budget reuse')
    finally:
        if sock is not None:
            sock.close()
        if process.poll() is None:
            process.kill()
        process.wait()


def verify_admission(executable, count):
    """Hold 15/16/17 requests open; the excess request bypasses client admission."""
    process = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    sock = None
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'startup timeout'
        sock = socket.create_connection(('127.0.0.1', int(process.stdout.readline())), timeout=5)
        conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        conn.initiate_connection()
        sock.sendall(conn.data_to_send())
        events = []

        def until(predicate):
            deadline = time.monotonic() + 5
            while not predicate():
                sock.settimeout(max(.001, deadline - time.monotonic()))
                data = sock.recv(65536)
                assert data, 'unexpected EOF'
                events.extend(conn.receive_data(data))
                sock.sendall(conn.data_to_send())
                assert time.monotonic() < deadline, 'admission progress timeout'

        # The server's advertised limit is acknowledged before opening streams.
        until(lambda: any(isinstance(e, SettingsAcknowledged) for e in events))
        assert conn.remote_settings.max_concurrent_streams == 16
        headers = [(':method', 'POST'), (':scheme', 'http'),
                   (':authority', 'localhost'), (':path', '/')]
        streams = list(range(1, 2 * min(count, 16), 2))
        for stream in streams:
            conn.send_headers(stream, headers, end_stream=False)
        conn.ping(b'admitted')
        sock.sendall(conn.data_to_send())
        # PING ACK proves all preceding open HEADERS have been processed.
        until(lambda: any(isinstance(e, PingAckReceived) and e.ping_data == b'admitted' for e in events))
        assert not any(isinstance(e, (StreamReset, StreamEnded, ConnectionTerminated)) for e in events)

        if count == 17:
            # H2Connection would reject this locally. Share its HPACK encoder so
            # the raw HEADERS has valid compression state, isolating admission.
            excess = HeadersFrame(33)
            excess.flags.add('END_HEADERS')
            excess.data = conn.encoder.encode(headers)
            sock.sendall(excess.serialize())
            until(lambda: any(isinstance(e, ConnectionTerminated) for e in events))
            goaway = next(e for e in events if isinstance(e, ConnectionTerminated))
            assert goaway.error_code == ErrorCodes.PROTOCOL_ERROR, goaway
            assert goaway.last_stream_id == 31, goaway
            assert not any(isinstance(e, (ResponseReceived, DataReceived, StreamEnded)) for e in events)
        else:
            # Reset one live request, then occupy its slot before completing any
            # other request. All remaining requests must survive and complete.
            conn.reset_stream(streams.pop(0), error_code=ErrorCodes.CANCEL)
            replacement = 2 * count + 1
            conn.send_headers(replacement, headers, end_stream=False)
            streams.append(replacement)
            for stream in streams:
                conn.end_stream(stream)
            sock.sendall(conn.data_to_send())
            until(lambda: set(streams) <= {e.stream_id for e in events if isinstance(e, StreamEnded)})
            assert not any(isinstance(e, (StreamReset, ConnectionTerminated)) for e in events)
            responses = {e.stream_id: dict(e.headers)[':status'] for e in events if isinstance(e, ResponseReceived)}
            assert responses == dict.fromkeys(streams, '200'), responses
            assert not any(isinstance(e, DataReceived) and e.data for e in events)
            # Completion also frees admission slots for subsequent requests.
            later = replacement + 2
            conn.send_headers(later, headers, end_stream=True)
            sock.sendall(conn.data_to_send())
            until(lambda: any(isinstance(e, StreamEnded) and e.stream_id == later for e in events))
            assert not any(isinstance(e, (StreamReset, ConnectionTerminated)) for e in events)
            assert any(isinstance(e, ResponseReceived) and e.stream_id == later and
                       dict(e.headers)[':status'] == '200' for e in events)

        sock.close()
        sock = None
        _, stderr = process.communicate(timeout=10)
        # Engine.destroy also asserts that every session allocation was freed.
        assert process.returncode == 0, stderr
        metrics = dict(part.split('=') for part in stderr.strip().split())
        assert int(metrics['peak_streams']) == min(count, 16), metrics
        assert int(metrics['admitted']) == (16 if count == 17 else count + 2), metrics
        if count != 17:
            assert int(metrics['active']) == 0, metrics
            assert int(metrics['closed']) == count + 2, metrics
        print(f'PASS {count} simultaneous streams: ' +
              ('excess rejected by GOAWAY; session destroyed' if count == 17 else
               'reset/completion release slots; connection reused'))
    finally:
        if sock is not None:
            sock.close()
        if process.poll() is None:
            process.kill()
        process.wait()


def verify_connections(executable, disconnect=False):
    """A socket-blocked connection yields to another owner, then resumes."""
    process = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    sockets = []
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'startup timeout'
        port = int(process.stdout.readline())
        slow = socket.socket()
        sockets.append(slow)
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        slow.settimeout(5)
        slow.connect(('127.0.0.1', port))
        conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        conn.initiate_connection()
        conn.increment_flow_control_window(1024 * 1024)
        headers = [(':method', 'POST'), (':scheme', 'http'),
                   (':authority', 'localhost'), (':path', '/')]
        payload = b'x' * 4096
        # Below connection input credit: force socket backpressure, not HTTP/2
        # credit exhaustion. Each response fits its stream's default window.
        for stream in range(1, 30, 2):
            conn.send_headers(stream, headers)
            conn.send_data(stream, payload, end_stream=True)
        slow.sendall(conn.data_to_send())
        assert select.select([process.stdout], [], [], 5)[0], 'server never blocked on socket output'
        assert process.stdout.readline().strip() == 'blocked=1'

        fast = socket.create_connection(('127.0.0.1', port), timeout=5)
        sockets.append(fast)
        fast_conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        fast_conn.initiate_connection()

        def exchange(sock, client, stream, expected, half_close=False):
            client.send_headers(stream, headers)
            client.send_data(stream, expected, end_stream=True)
            sock.sendall(client.data_to_send())
            if half_close:
                sock.shutdown(socket.SHUT_WR)
            received = b''
            status = None
            while True:
                data = sock.recv(65536)
                assert data, 'other connection unexpectedly closed'
                for event in client.receive_data(data):
                    assert not isinstance(event, (StreamReset, ConnectionTerminated)), event
                    if isinstance(event, ResponseReceived) and event.stream_id == stream:
                        status = dict(event.headers)[':status']
                    elif isinstance(event, DataReceived) and event.stream_id == stream:
                        received += event.data
                    elif isinstance(event, StreamEnded) and event.stream_id == stream:
                        assert status == '200' and received == expected
                        return
                if not half_close:
                    sock.sendall(client.data_to_send())

        exchange(fast, fast_conn, 1, b'while other socket is blocked')
        if disconnect:
            # Abort while output is retained, without draining the socket.
            slow.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        else:
            # Reading again must wake the writer through the kernel writable watch.
            ended, bodies, statuses = set(), defaultdict(bytes), {}
            deadline = time.monotonic() + 10
            while len(ended) != 15:
                slow.settimeout(max(.001, deadline - time.monotonic()))
                data = slow.recv(65536)
                assert data
                for event in conn.receive_data(data):
                    assert not isinstance(event, (StreamReset, ConnectionTerminated)), event
                    if isinstance(event, ResponseReceived):
                        statuses[event.stream_id] = dict(event.headers)[':status']
                    elif isinstance(event, DataReceived):
                        bodies[event.stream_id] += event.data
                    elif isinstance(event, StreamEnded):
                        ended.add(event.stream_id)
                slow.sendall(conn.data_to_send())
            assert ended == set(range(1, 30, 2))
            assert all(bodies[stream] == payload and statuses[stream] == '200' for stream in ended)
        slow.close()
        sockets.remove(slow)
        exchange(fast, fast_conn, 3, b'after other connection closes')
        # A protocol failure also stays local to its connection.
        malformed = socket.create_connection(('127.0.0.1', port), timeout=5)
        sockets.append(malformed)
        malformed.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
        # Initial server SETTINGS may precede detection of the invalid preface.
        while malformed.recv(65536):
            pass
        malformed.close()
        sockets.remove(malformed)
        exchange(fast, fast_conn, 5, b'after invalid peer preface')
        # Reuse the freed fixture slot with a new readiness identity.
        replacement = socket.create_connection(('127.0.0.1', port), timeout=5)
        sockets.append(replacement)
        new_conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        new_conn.initiate_connection()
        exchange(replacement, new_conn, 1, b'replacement connection', half_close=True)
        for sock in sockets:
            sock.close()
        sockets.clear()
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        metrics = [dict(part.split('=') for part in line.split()) for line in stderr.strip().splitlines()]
        assert len(metrics) == 4, metrics
        assert sorted(int(m['admitted']) for m in metrics) == [0, 1, 3, 15], metrics
        completed_metrics = [m for m in metrics if m['admitted'] != '15'] if disconnect else metrics
        assert all(m['active'] == '0' and m['admitted'] == m['closed'] for m in completed_metrics), metrics
        print('PASS socket backpressure, independent connection progress, ' +
              ('blocked disconnect cleanup' if disconnect else 'writable resumption') +
              ', slot reuse and TCP half-close')
    finally:
        for sock in sockets:
            sock.close()
        if process.poll() is None:
            process.kill()
        process.wait()


def verify_trailers(executable):
    process = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([process.stdout], [], [], 5)[0]
        port = int(process.stdout.readline())
        with socket.create_connection(('127.0.0.1', port), timeout=5) as sock:
            conn = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
            conn.initiate_connection()
            conn.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 0})
            for sid, data in ((1, b'body'), (3, b'')):
                conn.send_headers(sid, [(':method', 'POST'), (':scheme', 'http'),
                    (':authority', 'localhost'), (':path', '/trailers')], end_stream=not data)
                if data:
                    conn.send_data(sid, data, end_stream=True)
            sock.sendall(conn.data_to_send())
            ended, trailers, bodies = set(), {}, defaultdict(bytes)
            def receive_until(predicate):
                while not predicate():
                    wire = sock.recv(65536)
                    assert wire
                    for event in conn.receive_data(wire):
                        assert not isinstance(event, (StreamReset, ConnectionTerminated)), event
                        if isinstance(event, DataReceived): bodies[event.stream_id] += event.data
                        if isinstance(event, TrailersReceived): trailers[event.stream_id] = dict(event.headers)
                        if isinstance(event, StreamEnded):
                            assert event.stream_id in trailers, 'EOF before final fields'
                            ended.add(event.stream_id)
                    pending = conn.data_to_send()
                    if pending: sock.sendall(pending)
            receive_until(lambda: 3 in ended)
            assert 1 not in ended and bodies[1] == b''
            conn.increment_flow_control_window(4, stream_id=1)
            sock.sendall(conn.data_to_send())
            receive_until(lambda: 1 in ended)
            assert bodies[1] == b'body' and bodies[3] == b''
            assert trailers == {1: {'x-result': 'done'}, 3: {'x-result': 'done'}}
        _, errors = process.communicate(timeout=10)
        assert process.returncode == 0, errors
        print('PASS trailers: zero-credit empty response and exact-credit body completion')
    finally:
        if process.poll() is None: process.kill()
        process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server')
    executable = parser.parse_args().server
    verify_trailers(executable)
    verify(executable)
    verify_header_budget(executable)
    verify_input_budget(executable)
    for count in (15, 16, 17):
        verify_admission(executable, count)
    verify_connections(executable)
    verify_connections(executable, disconnect=True)
