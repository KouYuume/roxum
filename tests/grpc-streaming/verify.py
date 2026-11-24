"""Generated streaming interoperability on production TCP and Unix listeners."""
from contextlib import ExitStack
import json
import pathlib
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time

import grpc
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'zig-out/grpc-streaming'))
import streaming_pb2 as messages
import streaming_pb2_grpc as services
sys.path.insert(0, str(ROOT / 'tests/support'))
from roxum_process import stop
sys.path.insert(0, str(ROOT / "tests/grpc-unary"))
import proxy


def verify_decoder_exhaustion(channel):
    submit = channel.stream_unary('/heap/streaming.Uploads/Submit',
                                  request_serializer=messages.Request.SerializeToString,
                                  response_deserializer=messages.Update.FromString)
    def expect_exhaustion(call):
        try:
            call()
        except grpc.RpcError as exc:
            assert exc.code() == grpc.StatusCode.RESOURCE_EXHAUSTED and exc.details() == 'message allocation limit', exc
        else:
            raise AssertionError('expected decoder allocation limit')

    # The frame fits the route limit. Copying its payload exceeds the decoder heap.
    oversized = messages.Request(mode='x' * (8 * 1024 * 1024))
    expect_exhaustion(lambda: submit(iter([oversized]), timeout=30))
    result = submit(iter([messages.Request(count=1)]), timeout=5)
    assert result == messages.Update(sequence=1, text='total')

    # These small frames fit the input heap. Only the codec expansion can fail.
    options = dict(request_serializer=messages.Request.SerializeToString,
                   response_deserializer=messages.Update.FromString)
    request = messages.Request(count=8 * 1024 * 1024, mode='expand')
    chat = channel.stream_stream('/heap/chat', **options)
    # The duplex route has a zero application status-message budget.
    expect_exhaustion(lambda: list(chat(iter([oversized]), timeout=30)))
    calls = [
        lambda: channel.unary_unary('/heap/echo', **options)(request, timeout=5),
        lambda: list(channel.unary_stream('/heap/watch', **options)(request, timeout=5)),
        lambda: channel.stream_unary('/heap/submit', **options)(iter([request]), timeout=5),
        lambda: list(chat(iter([request]), timeout=5)),
    ]
    for call in calls:
        expect_exhaustion(call)
        assert submit(iter([messages.Request(count=1)]), timeout=5) == result

    raw_chat = channel.stream_stream('/heap/chat')
    for payload, code, detail in (
        (b'\xff', grpc.StatusCode.INVALID_ARGUMENT, 'invalid Protobuf message'),
        (messages.Request(mode='deny').SerializeToString(), grpc.StatusCode.INTERNAL, 'invalid application status'),
    ):
        try:
            list(raw_chat(iter([payload]), timeout=5))
        except grpc.RpcError as exc:
            assert exc.code() == code and exc.details() == detail, exc
        else:
            raise AssertionError('expected duplex failure')


def verify_duplex(channel):
    chat = services.ExchangeStub(channel).Chat
    release = threading.Event()

    def requests():
        yield messages.Request(count=1, mode="count-reads")
        if release.wait(5):
            # Larger than the host's 16 KiB read chunk on every transport.
            yield messages.Request(mode='x' * 32768)

    call = chat(requests(), timeout=10)
    try:
        assert next(call) == messages.Update(sequence=1, text='ack')
        release.set()
        assert list(call) == [messages.Update(sequence=1, text='reads')]
        assert call.code() == grpc.StatusCode.OK
    finally:
        release.set()
        call.cancel()

    # The server completes successfully while the request generator is still open.
    stop_sending = threading.Event()
    def open_request():
        yield messages.Request(mode='finish')
        stop_sending.wait()
    try:
        early = chat(open_request(), timeout=5)
        assert list(early) == [] and early.code() == grpc.StatusCode.OK
    finally:
        stop_sending.set()

    # One small request drives output count across the eight-message boundary.
    # Two small requests drive encoded output to 65543, 65544, or 65545 bytes.
    for mode, values, accepted, code in (
        ('burst', [7], 7, grpc.StatusCode.OK),
        ('burst', [8], 8, grpc.StatusCode.OK),
        ('burst', [9], 8, grpc.StatusCode.RESOURCE_EXHAUSTED),
        ('sized', [32768, 32767], 2, grpc.StatusCode.OK),
        ('sized', [32768, 32768], 2, grpc.StatusCode.OK),
        ('sized', [32768, 32769], 1, grpc.StatusCode.RESOURCE_EXHAUSTED),
    ):
        call = chat((messages.Request(mode=mode, count=n) for n in values), timeout=5)
        received = []
        try:
            received.extend(call)
        except grpc.RpcError:
            pass
        assert call.code() == code and len(received) == accepted, (mode, values, call.code(), received)
        if mode == 'sized':
            assert [m.ByteSize() for m in received] == [n + 4 for n in values[:accepted]]

    # A valid gRPC envelope can still contain an invalid Protobuf payload.
    raw = channel.stream_stream('/streaming.Exchange/Chat', response_deserializer=messages.Update.FromString)
    call = raw(iter([messages.Request(count=3).SerializeToString(), b'\xff']), timeout=5)
    try:
        list(call)
    except grpc.RpcError as exc:
        assert exc.code() == grpc.StatusCode.INVALID_ARGUMENT, exc
    else:
        raise AssertionError('duplex accepted invalid protobuf')


def verify_duplex_pressure(channel, address, unix):
    from pressure import Peer
    stub = services.UpdatesStub(channel)
    def observed():
        return stub.Echo(messages.Request(mode='observed'), timeout=3).sequence

    # A direct peer controls the production listener's stream window.
    for scenario in ('deny', 'reset', 'exhaust', 'exhaust-reset'):
        exhaust = scenario.startswith('exhaust')
        cancel = scenario.endswith('reset')
        before = observed()
        with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as sock:
            sock.settimeout(5)
            sock.connect(address)
            peer = Peer(sock, False)
            peer.h2.send_headers(1, [(':method', 'POST'), (':scheme', 'http'), (':authority', 'localhost'),
                (':path', '/heap/chat' if exhaust else '/streaming.Exchange/Chat'), ('content-type', 'application/grpc'), ('te', 'trailers')])
            def frame(mode, count=7):
                payload = messages.Request(count=count, mode=mode).SerializeToString()
                return b'\0' + len(payload).to_bytes(4, 'big') + payload
            def send(data, end_stream=False):
                peer.h2.send_data(1, data, end_stream=end_stream)
                peer.flush()
            send(frame('large'))
            data = bytearray()
            while len(data) < 8192:
                for event in peer.receive():
                    if isinstance(event, DataReceived):
                        data.extend(event.data)
            assert len(data) == 8192
            if exhaust:
                # Both messages enter the same read callback while output is blocked.
                send(frame('observe') + frame('expand', 8 * 1024 * 1024), end_stream=True)
            else:
                send(frame('observe' if cancel else 'deny'), end_stream=not cancel)
            deadline = time.monotonic() + 5
            while observed() == before:
                assert time.monotonic() < deadline, 'duplex input stalled behind output'
            if cancel:
                if exhaust:
                    # Drain beyond the first accepted 16 KiB chunk, then cancel
                    # while the completion is still waiting to send its suffix.
                    peer.h2.increment_flow_control_window(32768, stream_id=1)
                    peer.flush()
                    while len(data) < 40960:
                        for event in peer.receive():
                            assert not isinstance(event, (TrailersReceived, StreamEnded, StreamReset)), event
                            if isinstance(event, DataReceived):
                                data.extend(event.data)
                peer.h2.reset_stream(1)
                peer.flush()
                peer.echo()
                continue
            # Fail input halfway through an outgoing envelope. Its remaining
            # bytes must precede the error trailers once credit becomes available.
            peer.h2.increment_flow_control_window(131072, stream_id=1)
            peer.flush()
            statuses = []
            ended = False
            while not ended:
                for event in peer.receive():
                    if isinstance(event, DataReceived):
                        data.extend(event.data)
                    elif isinstance(event, TrailersReceived):
                        statuses.append(dict(event.headers))
                    elif isinstance(event, StreamEnded):
                        ended = True
            expected = messages.Update(sequence=7, text='x' * 65536).SerializeToString()
            assert data == b'\0' + len(expected).to_bytes(4, 'big') + expected
            assert [entry['grpc-status'] for entry in statuses] == ['8' if exhaust else '7'], statuses
            if exhaust:
                assert statuses[0]['grpc-message'] == 'message%20allocation%20limit', statuses
            peer.echo()


def verify_upload(channel, address, unix, tls_context):
    submit = services.UploadsStub(channel).Submit
    for count in (0, 1, 3, 4):
        result = submit((messages.Request(count=i) for i in range(count)), timeout=5)
        assert result.sequence == sum(range(count)) and result.text == 'total'
    maximum = (1 << 32) - 1
    for increment in (0, 1, 2):
        requests = (messages.Request(count=value) for value in (maximum - 1, increment))
        try:
            reply = submit(requests, timeout=5)
        except grpc.RpcError as exc:
            assert increment == 2 and exc.code() == grpc.StatusCode.OUT_OF_RANGE, exc
        else:
            assert increment < 2 and reply.sequence == maximum - 1 + increment
    # A short nonempty mode string occupies two extra bytes for its tag and length.
    for sizes, code in (
        ([31], grpc.StatusCode.OK), ([32], grpc.StatusCode.OK), ([33], grpc.StatusCode.RESOURCE_EXHAUSTED),
        ([20, 19], grpc.StatusCode.OK), ([20, 20], grpc.StatusCode.OK), ([20, 21], grpc.StatusCode.RESOURCE_EXHAUSTED),
        ([0] * 5, grpc.StatusCode.RESOURCE_EXHAUSTED),
    ):
        requests = [messages.Request(mode='x' * max(0, size - 2)) for size in sizes]
        assert [msg.ByteSize() for msg in requests] == sizes
        try:
            reply = submit(iter(requests), timeout=5)
        except grpc.RpcError as exc:
            assert exc.code() == code, exc
        else:
            assert code == grpc.StatusCode.OK and reply.text == 'total', sizes

    body = messages.Request(mode='reject').SerializeToString()
    rejected = b'\0' + len(body).to_bytes(4, 'big') + body
    # Split one prefix and body, then finish it alongside another entire envelope.
    for parts, close, expected in (
        ([b'\0', b'\0\0\0\2\x08', b'\x02' + b'\0' * 5], True, '0'),
        ([b'\0' * 4], True, '3'),
        ([b'\0\0\0\0\2x'], True, '3'),
        ([b'\0\0\0\0\1\xff'], True, '3'),
        ([b'\x01' + b'\0' * 4], False, '12'),
        ([b'\x02' + b'\0' * 4], False, '3'),
        ([b'\0\0\0\0\x21'], False, '8'),
        ([rejected], False, '7'),
    ):
        sock = socket.socket(socket.AF_UNIX if unix and not tls_context else socket.AF_INET)
        if tls_context:
            sock = tls_context.wrap_socket(sock, server_hostname='localhost')
        with sock:
            sock.settimeout(5)
            sock.connect(address)
            client = H2Connection(config=H2Configuration(header_encoding='utf-8'))
            client.initiate_connection()
            client.send_headers(1, [(':method', 'POST'), (':scheme', 'https' if tls_context else 'http'),
                (':authority', 'localhost'), (':path', '/streaming.Uploads/Submit'),
                ('content-type', 'application/grpc'), ('te', 'trailers')])
            for index, part in enumerate(parts):
                client.send_data(1, part, end_stream=close and index == len(parts) - 1)
            sock.sendall(client.data_to_send())
            statuses, output = [], bytearray()
            ended = False
            while not ended:
                data = sock.recv(65536)
                assert data, 'unexpected disconnect'
                for event in client.receive_data(data):
                    if isinstance(event, (ResponseReceived, TrailersReceived)):
                        statuses.extend(v for k, v in event.headers if k == 'grpc-status')
                    elif isinstance(event, DataReceived):
                        output.extend(event.data)
                    elif isinstance(event, StreamEnded):
                        ended = True
                sock.sendall(client.data_to_send())
            assert statuses == [expected], (parts, statuses)
            if expected == '0':
                reply = messages.Update(sequence=2, text='total').SerializeToString()
                assert output == b'\0' + len(reply).to_bytes(4, 'big') + reply
            else:
                assert not output


def verify(executable, unix, proxied=False):
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-stream-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'rpc.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\n')
        with tempfile.TemporaryFile(mode='w+') as errors, ExitStack() as stack:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
                endpoint = process.stdout.readline().strip()
                target = endpoint if unix else '127.0.0.1:' + endpoint
                address = path if unix else ('127.0.0.1', int(endpoint))
                tls_context = None
                if proxied:
                    upstream = 'unix:' + path if unix else 'grpc://' + target
                    target, address, tls_context, certificate = stack.enter_context(proxy.start(upstream, directory))
                def channel_for_target():
                    credentials = grpc.ssl_channel_credentials(certificate) if proxied else None
                    options = (('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0))
                    return grpc.secure_channel(target, credentials, options=options) if proxied else grpc.insecure_channel(target, options=options)
                with channel_for_target() as channel:
                    grpc.channel_ready_future(channel).result(timeout=10)
                    if not proxied and not unix:
                        verify_decoder_exhaustion(channel)
                    verify_duplex(channel)
                    if not proxied:
                        verify_duplex_pressure(channel, address, unix)
                    verify_upload(channel, address, unix, tls_context)
                    stub = services.UpdatesStub(channel)
                    def stream(count, mode='', metadata=()):
                        call = stub.Watch(messages.Request(count=count, mode=mode), timeout=5, metadata=metadata)
                        received = []
                        try:
                            received.extend(call)
                        except grpc.RpcError:
                            pass
                        return received, call
                    # Empty output is successful and still carries final metadata.
                    for count in (0, 1, 3, 4, 5):
                        received, call = stream(count)
                        assert [m.sequence for m in received] == list(range(min(count, 4)))
                        assert all(m.text == 'item' for m in received)
                        assert ('source', 'stream') in call.initial_metadata()
                        assert call.code() == (grpc.StatusCode.OK if count <= 4 else grpc.StatusCode.RESOURCE_EXHAUSTED), call.details()
                        if count <= 4:
                            assert ('done', 'yes') in call.trailing_metadata()
                    for mode, code, count in (
                        ('reject', grpc.StatusCode.PERMISSION_DENIED, 0),
                        ('error', grpc.StatusCode.ABORTED, 1),
                        ('invalid-status', grpc.StatusCode.INTERNAL, 1),
                        ('oversized', grpc.StatusCode.INTERNAL, 0),
                        ('payload', grpc.StatusCode.RESOURCE_EXHAUSTED, 1),
                        ('bad-initial', grpc.StatusCode.INTERNAL, 0),
                        ('bad-trailing', grpc.StatusCode.INTERNAL, 3),
                    ):
                        received, call = stream(3, mode)
                        assert len(received) == count and call.code() == code, (mode, received, call.code(), call.details())
                    # Nearest values around the 64-byte per-message and
                    # cumulative payload caps (envelope bytes are excluded).
                    for mode, count, accepted, code in (
                        ('encoded-below', 1, 1, grpc.StatusCode.OK),
                        ('encoded-exact', 1, 1, grpc.StatusCode.OK),
                        ('encoded-above', 1, 0, grpc.StatusCode.INTERNAL),
                        ('payload-below', 2, 2, grpc.StatusCode.OK),
                        ('payload-exact', 2, 2, grpc.StatusCode.OK),
                        ('payload-above', 2, 1, grpc.StatusCode.RESOURCE_EXHAUSTED),
                    ):
                        received, call = stream(count, mode)
                        assert len(received) == accepted and call.code() == code, (mode, received, call.code(), call.details())
                    # The client deadline is long; the server's metadata-anchored
                    # duration triggers status 4 after the first message.
                    received, call = stream(2, 'deadline')
                    assert [m.sequence for m in received] == [0]
                    assert call.code() == grpc.StatusCode.DEADLINE_EXCEEDED
                    assert stub.Echo(messages.Request(count=42), timeout=5).sequence == 42
                # The producer is held by an explicit peer-observation latch.
                # It cannot finish until this client has received a full message.
                for mode in ('gated', 'deadline'):
                    with (tls_context.wrap_socket(socket.socket(), server_hostname='localhost') if proxied else socket.socket(socket.AF_UNIX if unix else socket.AF_INET)) as sock:
                        sock.settimeout(5)
                        sock.connect(address)
                        client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
                        client.initiate_connection()
                        body = messages.Request(count=2, mode=mode).SerializeToString()
                        headers = [(':method', 'POST'), (':scheme', 'https' if proxied else 'http'), (':authority', 'localhost'),
                                   (':path', '/streaming.Updates/Watch'), ('content-type', 'application/grpc'), ('te', 'trailers')]
                        if mode == 'deadline':
                            headers.append(('grpc-timeout', '1S'))
                        client.send_headers(1, headers)
                        client.send_data(1, b'\0' + len(body).to_bytes(4, 'big') + body, end_stream=True)
                        sock.sendall(client.data_to_send())
                        output, terminal, ended = b'', [], False
                        first_seen = False
                        while not ended:
                            wire = sock.recv(65536)
                            assert wire
                            for event in client.receive_data(wire):
                                assert not isinstance(event, StreamReset), event
                                if isinstance(event, DataReceived):
                                    output += event.data
                                    client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                                elif isinstance(event, TrailersReceived):
                                    terminal.append(dict(event.headers))
                                elif isinstance(event, StreamEnded):
                                    ended = True
                            if not first_seen and len(output) >= 5 and len(output) >= 5 + int.from_bytes(output[1:5], 'big'):
                                first_seen = True
                                if mode == 'gated':
                                    assert not ended, 'producer completed before peer observation'
                                    with channel_for_target() as release_channel:
                                        reply = services.UpdatesStub(release_channel).Echo(messages.Request(mode='release', count=42), timeout=5)
                                        assert reply.sequence == 42
                            sock.sendall(client.data_to_send())
                        # A raw peer cannot synthesize DEADLINE_EXCEEDED: status4
                        # must arrive in the server's terminal HEADERS, once.
                        assert len(terminal) == 1
                        assert terminal[0]['grpc-status'] == ('4' if mode == 'deadline' else '0'), terminal
                        if mode == 'deadline':
                            assert terminal[0]['grpc-message'] == 'deadline%20exceeded'
                        decoded = []
                        while output:
                            assert len(output) >= 5 and output[0] == 0
                            length = int.from_bytes(output[1:5], 'big')
                            assert len(output) >= length + 5
                            decoded.append(messages.Update.FromString(output[5:5 + length]))
                            output = output[5 + length:]
                        assert [m.sequence for m in decoded] == ([0] if mode == 'deadline' else [0, 1])
                assert stop(process) == 0
                errors.seek(0)
                diagnostic = errors.read()
                assert 'panic' not in diagnostic.lower(), diagnostic
            except BaseException:
                stop(process)
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                stop(process)
                process.stdout.close()
    print('PASS generated client/server streaming: messages, metadata, terminal errors, limits, expiry and Unary coexistence ' + ('TLS proxy -> ' if proxied else '') + ('Unix' if unix else 'TCP'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)

    verify(executable, False, True)
    verify(executable, True, True)
    import pressure
    acceptance = str(pathlib.Path(sys.argv[2]).resolve())
    for unix in (False, True):
        for proxied in (False, True):
            pressure.verify(acceptance, unix, proxied, sys.argv[3])
