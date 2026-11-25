"""Long generated input streams, expiry and active RPCs during server drain."""
import os
import signal
import threading
import time

import grpc
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.settings import SettingCodes
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived

from transport import scheme
import streaming_pb2 as messages
import streaming_pb2_grpc as services


def await_marker(progress, expected, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            count = progress()
        except grpc.RpcError as error:
            # A completed or cancelled RPC can still own the second request
            # slot when this observation is admitted. Only retry the probe.
            if error.code() != grpc.StatusCode.CANCELLED:
                raise
        else:
            if count == expected:
                return
            assert count < expected, (count, expected)
        time.sleep(.005)
    raise AssertionError(f'missing checkpoint {expected} or request capacity')


def long_inputs(channel_for_target, sample_rss, backend):
    checkpoints = (256, 1024, 2048)
    payload = 'x' * 16384
    with channel_for_target() as channel:
        echo = services.UpdatesStub(channel).Echo

        def progress():
            return echo(messages.Request(mode='progress'), timeout=5).sequence

        for duplex in (False, True):
            baseline = progress()
            gates = {index: threading.Event() for index in checkpoints}

            def requests():
                for index in range(1, checkpoints[-1] + 1):
                    yield messages.Request(count=index, mode=payload)
                    if index in gates and not gates[index].wait(30):
                        raise TimeoutError('checkpoint was not released')

            call = (services.ExchangeStub(channel).Chat(requests(), timeout=60) if duplex else
                    services.UploadsStub(channel).Submit.future(requests(), timeout=60))
            samples = []
            try:
                for ordinal, index in enumerate(checkpoints, 1):
                    if duplex:
                        assert next(call) == messages.Update(sequence=index, text='ack')
                    # The RPC is still open and its request iterator cannot run
                    # ahead. A concurrent Unary confirms application consumption.
                    await_marker(progress, baseline + ordinal, 20)
                    samples.append(sample_rss())
                    gates[index].set()
                if duplex:
                    assert list(call) == []
                else:
                    assert call.result() == messages.Update(sequence=checkpoints[-1], text='total')
                assert call.code() == grpc.StatusCode.OK
            finally:
                for gate in gates.values():
                    gate.set()
                call.cancel()
            print('input RSS bytes (4/16/32 MiB)', 'Chat' if duplex else 'Submit', samples, flush=True)
            if backend != 'interpreter':
                assert max(samples[1:]) <= samples[0] + 8 * 1024 * 1024, samples


def begin(sock, path, timeout=None, window=None):
    client = H2Connection(config=H2Configuration(header_encoding='utf-8'))
    client.initiate_connection()
    if window is not None:
        client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: window})
    request_headers(sock, client, 1, path, timeout)
    sock.sendall(client.data_to_send())
    return client


def request_headers(sock, client, stream, path, timeout=None):
    headers = [(':method', 'POST'), (':scheme', scheme(sock)), (':authority', 'localhost'),
               (':path', path), ('content-type', 'application/grpc'), ('te', 'trailers')]
    if timeout:
        headers.append(('grpc-timeout', timeout))
    client.send_headers(stream, headers)


def envelope(message):
    payload = message.SerializeToString()
    return b'\0' + len(payload).to_bytes(4, 'big') + payload


def interrupted_inputs(connect, channel_for_target, verify_recovery):
    with channel_for_target() as channel:
        echo = services.UpdatesStub(channel).Echo

        def progress():
            return echo(messages.Request(mode='progress'), timeout=5).sequence

        marker = envelope(messages.Request(count=1, mode='marker'))
        upload = '/streaming.Uploads/Submit'

        def verify_slots(sock, client, stream, expected):
            client.send_data(stream, marker)
            sock.sendall(client.data_to_send())
            # Submit holds one request slot until EOF. Observing its marker with
            # Echo requires the other slot previously used by the cancelled RPC.
            await_marker(progress, expected, 5)
            client.end_stream(stream)
            sock.sendall(client.data_to_send())
            assert response(sock, client, '0', stream) == envelope(messages.Update(sequence=1, text='total'))
            verify_recovery()

        for path in (upload, '/streaming.Exchange/Chat'):
            for reset in (True, False):
                before = progress()
                with connect() as sock:
                    client = begin(sock, path)
                    client.send_data(1, marker + b'\0\0\0\0\x02\x08')
                    sock.sendall(client.data_to_send())
                    await_marker(progress, before + 1, 5)
                    if reset:
                        client.reset_stream(1)
                        request_headers(sock, client, 3, upload)
                        verify_slots(sock, client, 3, before + 2)
                if not reset:
                    with connect() as probe:
                        verify_slots(probe, begin(probe, upload), 1, before + 2)


def response(sock, client, status, stream=1):
    statuses, data = [], bytearray()
    ended = False
    while not ended:
        wire = sock.recv(65536)
        assert wire
        for event in client.receive_data(wire):
            if getattr(event, 'stream_id', None) != stream:
                continue
            if isinstance(event, (ResponseReceived, TrailersReceived)):
                statuses.extend(v for k, v in event.headers if k == 'grpc-status')
            if isinstance(event, DataReceived):
                data.extend(event.data)
            if isinstance(event, StreamEnded):
                ended = True
            if isinstance(event, StreamReset):
                assert ended and event.error_code == 0, event
        sock.sendall(client.data_to_send())
    assert statuses == [status], statuses
    return data


def deadlines(connect):
    with connect() as sock:
        client = begin(sock, '/streaming.Exchange/Chat', '1S', window=8192)
        client.send_data(1, envelope(messages.Request(count=1, mode='large')), end_stream=True)
        sock.sendall(client.data_to_send())
        prefix = bytearray()
        while len(prefix) < 8192:
            wire = sock.recv(65536)
            assert wire
            for event in client.receive_data(wire):
                assert not isinstance(event, (TrailersReceived, StreamEnded, StreamReset)), event
                if isinstance(event, DataReceived):
                    prefix.extend(event.data)
            sock.sendall(client.data_to_send())
        assert len(prefix) == 8192
        # A second, later metadata-anchored deadline establishes that the first
        # elapsed while its response window was zero. Unary output needs no writer slot.
        with connect() as upload:
            other = begin(upload, '/streaming.Uploads/Submit', '1S')
            other.send_data(1, envelope(messages.Request(count=1)) + b'\0\0\0\0\x02\x08')
            upload.sendall(other.data_to_send())
            assert response(upload, other, '4') == b''
        client.increment_flow_control_window(131072, stream_id=1)
        sock.sendall(client.data_to_send())
        prefix.extend(response(sock, client, '4'))
        frame = envelope(messages.Update(sequence=1, text='y' * 65536))
        assert len(prefix) < len(frame) and frame.startswith(prefix), len(prefix)


def expect_ack(sock, client):
    expected = envelope(messages.Update(sequence=1, text='ack'))
    data = bytearray()
    while len(data) < len(expected):
        wire = sock.recv(65536)
        assert wire
        for event in client.receive_data(wire):
            assert not isinstance(event, (StreamEnded, StreamReset)), event
            if isinstance(event, DataReceived):
                data.extend(event.data)
        sock.sendall(client.data_to_send())
    assert data == expected


def drain(process, connect, forced):
    with connect() as sock:
        client = begin(sock, '/streaming.Exchange/Chat')
        client.send_data(1, envelope(messages.Request(count=1)))
        sock.sendall(client.data_to_send())
        expect_ack(sock, client)
        os.killpg(process.pid, signal.SIGTERM)
        # hyper-h2 closes the connection on GOAWAY. Decode that frame here so
        # the admitted stream can finish a second exchange after the signal.
        with sock.makefile('rb') as reader:
            goaway, ended, statuses = False, False, []
            reply = bytearray()
            expected = envelope(messages.Update(sequence=2, text="ack"))
            while True:
                header = reader.read(9)
                if not header:
                    break
                assert len(header) == 9
                size = int.from_bytes(header[:3], 'big')
                payload = reader.read(size)
                assert len(payload) == size
                if header[3] == 7:
                    assert header[5:] == bytes(4) and size >= 8
                    assert int.from_bytes(payload[:4], 'big') >= 1
                    assert payload[4:8] == bytes(4)
                    if not goaway and not forced:
                        client.send_data(1, envelope(messages.Request(count=2)), end_stream=True)
                        sock.sendall(client.data_to_send())
                    goaway = True
                    continue
                for event in client.receive_data(header + payload):
                    assert not isinstance(event, StreamReset), event
                    if isinstance(event, (DataReceived, TrailersReceived, StreamEnded)):
                        assert goaway and not forced and event.stream_id == 1, event
                    if isinstance(event, DataReceived):
                        reply.extend(event.data)
                    if isinstance(event, TrailersReceived):
                        assert reply == expected, reply
                        statuses.append(dict(event.headers).get('grpc-status'))
                    if isinstance(event, StreamEnded):
                        ended = True
            assert goaway and ended == (not forced)
            assert statuses == ([] if forced else ['0']), statuses
            assert reply == (b'' if forced else expected), reply
    assert process.wait(timeout=6) == (1 if forced else 0)
