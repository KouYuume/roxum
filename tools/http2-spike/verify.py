#!/usr/bin/env python3
"""Independent hyper-h2 checks for the disposable transport spike."""
import argparse
from collections import defaultdict
import re
import select
import socket
import subprocess
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, TrailersReceived, StreamEnded, ConnectionTerminated
from h2.settings import SettingCodes


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.h2 = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
        self.body = defaultdict(bytes)
        self.headers = {}
        self.trailers = {}
        self.ended = set()
        self.auto_credit = set()
        self.h2.initiate_connection()
        self.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 16})
        self.flush()

    def flush(self):
        self.sock.sendall(self.h2.data_to_send())

    def open(self, stream):
        self.h2.send_headers(stream, [(':method', 'POST'), (':scheme', 'http'),
                                     (':authority', 'localhost'), (':path', '/echo')])
        self.flush()

    def until(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate():
            self.sock.settimeout(max(0.001, deadline - time.monotonic()))
            data = self.sock.recv(65536)
            assert data, 'unexpected connection EOF'
            for event in self.h2.receive_data(data):
                if isinstance(event, DataReceived):
                    self.body[event.stream_id] += event.data
                    # Deliberately withhold stream credit, but not connection credit.
                    if event.stream_id in self.auto_credit:
                        self.h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif event.flow_controlled_length:
                        self.h2.increment_flow_control_window(event.flow_controlled_length)
                elif isinstance(event, ResponseReceived):
                    self.headers[event.stream_id] = dict(event.headers)
                elif isinstance(event, TrailersReceived):
                    self.trailers[event.stream_id] = dict(event.headers)
                elif isinstance(event, StreamEnded):
                    self.ended.add(event.stream_id)
                elif isinstance(event, ConnectionTerminated):
                    raise AssertionError(f'unexpected GOAWAY: {event}')
            self.flush()
            assert time.monotonic() < deadline, 'HTTP/2 progress timeout'

    def block_writer(self, stream):
        self.open(stream)
        self.until(lambda: self.body[stream] == b'ready\n')
        self.h2.send_data(stream, b'x' * 4096)
        self.flush()
        self.until(lambda: len(self.body[stream]) == 16 and
                   self.h2.local_flow_control_window(stream) >= 4096)
        # The first output buffer is still occupied. This second write must
        # suspend the handler, rather than merely leave queued protocol bytes.
        self.h2.send_data(stream, b'y' * 4096, end_stream=True)
        self.flush()
        assert stream not in self.ended

    def large_exchange(self, stream, size):
        self.open(stream)
        self.until(lambda: self.body[stream] == b'ready\n')
        resumed = False
        body = bytes(i % 251 for i in range(size))
        offset = 0
        while offset < size:
            self.until(lambda: self.h2.local_flow_control_window(stream) > 0)
            count = min(size - offset, self.h2.local_flow_control_window(stream),
                        self.h2.max_outbound_frame_size)
            self.h2.send_data(stream, body[offset:offset + count], end_stream=offset + count == size)
            offset += count
            self.flush()
            if not resumed:
                self.until(lambda: len(self.body[stream]) == 16)
                assert stream not in self.ended
                self.auto_credit.add(stream)
                self.h2.increment_flow_control_window(65535, stream_id=stream)
                self.flush()
                resumed = True
        self.until(lambda: stream in self.ended)
        assert self.body[stream] == b'ready\n' + body
        assert self.trailers[stream] == {'x-spike-complete': 'yes'}

    def finish(self, stream, body):
        self.h2.send_data(stream, body, end_stream=True)
        self.flush()
        self.until(lambda: stream in self.ended)
        assert self.headers[stream][':status'] == '200'
        assert self.body[stream] == b'ready\n' + body
        assert self.trailers[stream] == {'x-spike-complete': 'yes'}


def run(executable, disconnect=False):
    process = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    client = None
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'listener startup timeout'
        line = process.stdout.readline()
        assert line.strip().isdigit(), 'listener did not report a port'
        client = Client(int(line))
        client.open(1)
        client.open(3)
        client.until(lambda: client.body[1] == client.body[3] == b'ready\n')
        assert not client.ended, 'response ended before request EOF'
        if not disconnect:
            client.h2.reset_stream(1, error_code=8)
            client.flush()
            client.finish(3, b'hello')
            client.open(5)
            client.finish(5, b'')
            # A stalled writer consumes its small receive window. Another stream
            # must complete while that writer is suspended, then survive its reset.
            client.block_writer(7)
            client.open(9)
            client.finish(9, b'ok')
            client.h2.reset_stream(7, error_code=8)
            client.flush()
            client.open(11)
            client.finish(11, b'after')
            # The server's input window and buffer boundary, including resumption.
            for stream, size in [(13, 4095), (15, 4096), (17, 4097)]:
                client.large_exchange(stream, size)
            # Response sizes immediately below, at, and above the 16-byte window.
            for stream, size in [(23, 9), (25, 10), (27, 11)]:
                client.open(stream)
                body = b'z' * size
                client.h2.send_data(stream, body, end_stream=True)
                client.flush()
                if size == 11:
                    client.until(lambda: len(client.body[stream]) == 16)
                    assert stream not in client.ended
                    client.h2.increment_flow_control_window(1, stream_id=stream)
                    client.flush()
                client.until(lambda: stream in client.ended)
                assert client.body[stream] == b'ready\n' + body
                assert client.trailers[stream] == {'x-spike-complete': 'yes'}
            client.open(29)
            client.h2.send_data(29, b'z' * 10)
            client.flush()
            client.until(lambda: len(client.body[29]) == 16)
            client.h2.end_stream(29)
            client.flush()
            client.until(lambda: 29 in client.ended)
            assert client.body[29] == b'ready\n' + b'z' * 10
            assert client.trailers[29] == {'x-spike-complete': 'yes'}
            client.block_writer(31)
            client.open(33)
            client.finish(33, b'live')
            client.auto_credit.add(31)
            client.h2.increment_flow_control_window(65535, stream_id=31)
            client.flush()
            client.until(lambda: 31 in client.ended)
            assert client.body[31] == b'ready\n' + b'x' * 4096 + b'y' * 4096
            assert client.trailers[31] == {'x-spike-complete': 'yes'}
        client.sock.close()
        client = None
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        match = re.search(r'created=(\d+) destroyed=(\d+) cancelled=(\d+) allocations=(\d+) peak=(\d+) cancelled_writers=(\d+) resumed_writers=(\d+)', stderr)
        assert match, stderr
        created, destroyed, cancelled, allocations, peak, cancelled_writers, resumed_writers = map(int, match.groups())
        assert created == destroyed == (2 if disconnect else 15), stderr
        assert cancelled == (0 if disconnect else 2) and allocations == 0 and peak > 0, stderr
        assert cancelled_writers == (0 if disconnect else 1), stderr
        if not disconnect:
            assert resumed_writers >= 1, stderr
        print(('PASS disconnect with active readers' if disconnect else
               'PASS multiplexing, early response, trailers, reset isolation, blocked writer, connection reuse, input-window boundaries')
              + f'; {match.group(0)}')
    finally:
        if client:
            client.sock.close()
        if process.poll() is None:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server')
    args = parser.parse_args()
    run(args.server)
    run(args.server, disconnect=True)


if __name__ == '__main__':
    main()
