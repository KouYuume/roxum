"""Bounded output, peer progress and repeated cancellation on production listeners."""
from contextlib import ExitStack
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
import input_lifecycle
import proxy
import streaming_pb2 as messages


class Peer:
    def __init__(self, sock, proxied):
        self.sock = sock
        self.proxied = proxied
        self.pending = []
        self.h2 = H2Connection(config=H2Configuration(header_encoding='utf-8'))
        self.h2.initiate_connection()
        self.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 8192})
        self.flush()

    def flush(self):
        self.sock.sendall(self.h2.data_to_send())

    def begin(self, method, count, mode=''):
        stream = self.h2.get_next_available_stream_id()
        self.h2.send_headers(stream, [(':method', 'POST'), (':scheme', 'https' if self.proxied else 'http'),
            (':authority', 'localhost'), (':path', '/streaming.Updates/' + method),
            ('content-type', 'application/grpc'), ('te', 'trailers')])
        body = messages.Request(count=count, mode=mode).SerializeToString()
        self.h2.send_data(stream, b'\0' + len(body).to_bytes(4, 'big') + body, end_stream=True)
        self.flush()
        return stream

    def watch(self, count, mode=''):
        # Close/reset/END_STREAM on a peer is not a worker-cleanup barrier.
        # Wait only for the expected temporary writer-quota rejection; a leak
        # must still exhaust this deadline, not turn into an endless retry.
        deadline = time.monotonic() + 5
        timeout = self.sock.gettimeout()
        try:
            while True:
                remaining = deadline - time.monotonic()
                assert remaining > 0, 'writer quota was not released'
                self.sock.settimeout(min(timeout, remaining))
                stream = self.begin('Watch', count, mode)
                status, ended = None, False
                while not ended:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, 'writer quota was not released'
                    self.sock.settimeout(min(timeout, remaining))
                    events = self.receive()
                    for event in events:
                        if isinstance(event, ResponseReceived) and event.stream_id == stream:
                            status = dict(event.headers)[':status']
                    assert status in (None, '200', '503'), ('unexpected Watch status', status)
                    if status == '200':
                        self.pending = events
                        return stream
                    for event in events:
                        assert not isinstance(event, (DataReceived, TrailersReceived)), ('quota response has a body/trailers', event)
                        if isinstance(event, StreamEnded) and event.stream_id == stream:
                            ended = True
                    if ended:
                        assert status == '503', ('missing Watch status', status)
                time.sleep(min(.005, max(0, deadline - time.monotonic())))
        finally:
            self.sock.settimeout(timeout)

    def receive(self):
        if self.pending:
            events, self.pending = self.pending, []
            return events
        data = self.sock.recv(65536)
        assert data, 'unexpected disconnect'
        events = self.h2.receive_data(data)
        for event in events:
            assert not isinstance(event, StreamReset), event
            if isinstance(event, DataReceived):
                # Keep connection credit available while withholding stream credit.
                self.h2.increment_flow_control_window(event.flow_controlled_length)
        self.flush()
        return events

    def echo(self):
        stream = self.begin('Echo', 42)
        data, statuses = bytearray(), []
        while True:
            events = self.receive()
            for event in events:
                if isinstance(event, DataReceived):
                    assert event.stream_id == stream, 'stalled stream advanced without credit'
                    data.extend(event.data)
                if isinstance(event, TrailersReceived) and event.stream_id == stream:
                    statuses.append(dict(event.headers).get('grpc-status'))
                if isinstance(event, StreamEnded) and event.stream_id == stream:
                    assert statuses == ['0'], statuses
                    assert len(data) >= 5 and data[0] == 0
                    assert len(data) == 5 + int.from_bytes(data[1:5], 'big')
                    assert messages.Update.FromString(data[5:]).sequence == 42
                    return

    def stall(self, count=8192, retain=False):
        stream = self.watch(count)
        size, prefix = 0, bytearray()
        while size < 8192:
            for event in self.receive():
                if isinstance(event, DataReceived):
                    assert event.stream_id == stream
                    size += event.flow_controlled_length
                    prefix.extend(event.data)
                assert not isinstance(event, StreamEnded)
        assert size == 8192
        # Exactly zero stream credit establishes backpressure without a sleep.
        self.echo()
        return (stream, prefix) if retain else stream

    def reset(self, stream):
        self.h2.reset_stream(stream)
        self.flush()
        self.echo()

    def consume(self, count, checkpoint, stream=None, prefix=b''):
        resumed = stream is not None
        if not resumed:
            stream = self.watch(count)
        if self.h2.streams[stream].open:
            self.h2.increment_flow_control_window(65536 if resumed else 65536 - 8192, stream_id=stream)
        self.flush()
        buffer, index, statuses = bytearray(prefix), 0, []
        while True:
            for event in self.receive():
                if isinstance(event, DataReceived):
                    assert event.stream_id == stream
                    buffer.extend(event.data)
                    while len(buffer) >= 5:
                        length = int.from_bytes(buffer[1:5], 'big')
                        assert buffer[0] == 0 and length <= 8192
                        if len(buffer) < length + 5:
                            break
                        message = messages.Update.FromString(buffer[5:5 + length])
                        del buffer[:5 + length]
                        assert message.sequence == index and message.text == 'x' * 4096
                        index += 1
                        if index in (1024, 4096, 8192):
                            checkpoint(index)
                    if self.h2.streams[stream].open:
                        self.h2.increment_flow_control_window(event.flow_controlled_length, stream_id=stream)
                if isinstance(event, TrailersReceived):
                    statuses.append(dict(event.headers).get('grpc-status'))
                if isinstance(event, StreamEnded):
                    assert event.stream_id == stream
                    assert index == count and not buffer and statuses == ['0'], (index, statuses)
                    self.flush()
                    self.echo()
                    return
            self.flush()


def rss_tree(pid):
    """Resident bytes of the server supervisor and its workers (not this client)."""
    rows = [tuple(map(int, line.split())) for line in subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,rss='], text=True).splitlines() if line.strip()]
    included = {pid}
    while True:
        children = {child for child, parent, _ in rows if parent in included}
        if children <= included:
            break
        included |= children
    return sum(rss * 1024 for child, _, rss in rows if child in included)


def verify(executable, unix=False, proxied=False, backend="speed"):
    with tempfile.TemporaryDirectory(prefix='roxum-stream-pressure-', dir='/tmp') as directory, ExitStack() as stack:
        path = str(pathlib.Path(directory) / 'rpc.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        threads = 1 if backend == 'interpreter' else 2
        (config / 'local.toml').write_text(f'path = {json.dumps(path)}\nthreads = {threads}\n')
        errors = stack.enter_context(tempfile.TemporaryFile(mode='w+'))
        process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=errors,
                                   text=True, start_new_session=True)
        try:
            assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
            port = process.stdout.readline().strip()
            workers = set(ready_workers(process))
            address = path if unix else ('127.0.0.1', int(port))
            context = None
            if proxied:
                _, address, context, _ = stack.enter_context(proxy.start('unix:' + path if unix else 'grpc://127.0.0.1:' + port, directory))
            def connect():
                sock = context.wrap_socket(socket.socket(), server_hostname='localhost') if proxied else socket.socket(socket.AF_UNIX if unix else socket.AF_INET)
                if proxied or not unix:
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.settimeout(10)
                sock.connect(address)
                return sock
            def verify_recovery():
                with connect() as probe:
                    Peer(probe, proxied).consume(1, lambda _: None)

            if not proxied:
                target = 'unix:' + path if unix else '127.0.0.1:' + port
                input_lifecycle.long_inputs(target, lambda: rss_tree(process.pid), backend)
                input_lifecycle.interrupted_inputs(connect, target, verify_recovery)
                input_lifecycle.deadlines(connect)
                verify_recovery()
            with connect() as sock:
                peer = Peer(sock, proxied)
                # Repeated zero-credit resets must release the single writer slot.
                for _ in range(16):
                    peer.reset(peer.stall())
                # A producer suspended in another effect is also cancellable.
                for _ in range(16):
                    stream = peer.watch(2, 'wait')
                    while not any(isinstance(e, DataReceived) for e in peer.receive()):
                        pass
                    peer.reset(stream)
                samples = []
                def checkpoint(count):
                    samples.append((count, rss_tree(process.pid)))
                    # Probe while the long request is still alive: retaining its
                    # history must not be hidden by end-of-request cleanup.
                    with connect() as probe:
                        Peer(probe, proxied).echo()
                # 32 MiB traverses an 8 MiB request budget, with fixed 64 KiB credit.
                count = 256 if proxied else 8192
                stream, prefix = peer.stall(count, retain=True)
                peer.consume(count, checkpoint, stream, prefix)
                assert len(samples) == (0 if proxied else 3), samples
                # After 4 MiB warmup, a further 28 MiB must not remain resident.
                # Allow 8 MiB for allocator caches and runtime bookkeeping.
                if not proxied and backend != "interpreter":
                    assert max(value for _, value in samples[1:]) <= samples[0][1] + 8 * 1024 * 1024, samples
                if samples:
                    print('server RSS checkpoints (messages, bytes):', samples, flush=True)
            # Connection loss while output is blocked must release writer resources.
            for _ in range(4):
                with connect() as sock:
                    Peer(sock, proxied).stall()
            verify_recovery()
            # A replacement worker can serve new connections after a cleanup
            # crash; successful RPCs alone must not hide that failure.
            assert set(ready_workers(process)) == workers, "worker restarted during acceptance"
            if proxied:
                assert stop(process) == 0
            else:
                input_lifecycle.drain(process, connect, forced=unix)
            errors.seek(0)
            diagnostic = errors.read()
            assert 'panic' not in diagnostic.lower(), diagnostic
            if unix and not proxied:
                assert 'the drain timeout passed; 1 connections were cut' in diagnostic, diagnostic
        except BaseException:
            stop(process)
            errors.seek(0)
            print(errors.read())
            raise
        finally:
            stop(process)
            process.stdout.close()
    print('PASS pressure/cancellation ' + ('TLS proxy -> ' if proxied else '') + ('Unix' if unix else 'TCP'), flush=True)
