#!/usr/bin/env python3
"""Independent wire checks for the internal engine's finite-response contract."""
import argparse
from collections import defaultdict
import select
import socket
import subprocess
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, ConnectionTerminated
from h2.settings import SettingCodes


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
                        status[event.stream_id] = dict(event.headers)[':status']
                    elif isinstance(event, StreamEnded):
                        ended.add(event.stream_id)
                    elif isinstance(event, StreamReset):
                        reset.add(event.stream_id)
                    elif isinstance(event, ConnectionTerminated):
                        raise AssertionError(f'unexpected GOAWAY: {event}')
                flush()
                assert time.monotonic() < deadline, 'progress timeout'

        def request(stream, payload=b'', extra=(), end=True, method='POST'):
            conn.send_headers(stream, [(':method', method), (':scheme', 'http'),
                                      (':authority', 'localhost'), (':path', '/'), *extra], end_stream=end and not payload)
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

        # Disconnect with engine-owned response bytes still flow controlled.
        request(63, b'x' * 4096)
        until(lambda: len(body[63]) == 16)
        sock.close()
        sock = None
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        print('PASS multiplexing/reset, partial output, owned responses, 15/16/17 output, '
              'body/header bounds, 16 admitted streams, disconnect cleanup')
        print(stderr.strip())
    finally:
        if sock is not None:
            sock.close()
        if process.poll() is None:
            process.kill()
        process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server')
    verify(parser.parse_args().server)
