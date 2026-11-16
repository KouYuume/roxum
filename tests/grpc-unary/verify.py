"""Typed Unary interoperability using protoc-generated Python messages and grpcio."""
import os
from contextlib import ExitStack
import socket
import time
import struct
from h2.connection import H2Connection
from h2.events import StreamReset, StreamEnded, DataReceived, TrailersReceived, ResponseReceived
import json
import pathlib
import select
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "zig-out/protobuf-codegen"))
import service_pb2
import grpc
import service_pb2_grpc

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop
import proxy


def verify(executable, unix, proxied=False):
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-unary-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'rpc.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\n')
        with tempfile.TemporaryFile(mode='w+') as errors, ExitStack() as stack:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timed out'
                endpoint = process.stdout.readline().strip()
                target = endpoint if unix else f'127.0.0.1:{int(endpoint)}'
                address = path if unix else ('127.0.0.1', int(endpoint))
                tls_context = None
                if proxied:
                    upstream = 'unix:' + path if unix else 'grpc://' + target
                    target, address, tls_context, certificate = stack.enter_context(proxy.start(upstream, directory))
                    channel_context = grpc.secure_channel(target, grpc.ssl_channel_credentials(certificate), options=(('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0)))
                else:
                    channel_context = grpc.insecure_channel(target, options=(('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0)))
                with channel_context as channel:
                    grpc.channel_ready_future(channel).result(timeout=10)
                    call = service_pb2_grpc.GreeterStub(channel).Greet
                    result, completed = call.with_call(service_pb2.Greeting(name='Roc'), timeout=5, metadata=(('x-bin', b'\x00\xff'),))
                    assert result.greeting == 'Hello Roc'
                    assert ('x-bin', b'\x00\xff') in completed.trailing_metadata()
                    try:
                        call(service_pb2.Greeting(name='error'), timeout=5)
                    except grpc.RpcError as error:
                        assert error.code() == grpc.StatusCode.INVALID_ARGUMENT
                        assert error.details() == ' bad name '
                    else:
                        raise AssertionError('expected application failure')
                    for name in ('overflow', 'invalid-status', 'invalid-metadata'):
                        try: call(service_pb2.Greeting(name=name), timeout=5)
                        except grpc.RpcError as error: assert error.code() == grpc.StatusCode.INTERNAL
                        else: raise AssertionError('invalid application output accepted')
                    raw = channel.unary_unary('/unary.Greeter/Greet')
                    for value, status in [(b'\x0a\x05x', grpc.StatusCode.INVALID_ARGUMENT), (b'x'*65, grpc.StatusCode.RESOURCE_EXHAUSTED)]:
                        try: raw(value, timeout=5)
                        except grpc.RpcError as error: assert error.code() == status
                        else: raise AssertionError('invalid input accepted')
                    try: channel.unary_unary('/unary.Greeter/Missing')(b'', timeout=5)
                    except grpc.RpcError as error: assert error.code() == grpc.StatusCode.UNIMPLEMENTED
                    else: raise AssertionError('unknown method accepted')
                    assert call(service_pb2.Greeting(name='peer'), timeout=5).greeting == 'Hello peer'
                with (tls_context.wrap_socket(socket.socket(), server_hostname='localhost') if proxied else socket.socket(socket.AF_UNIX if unix else socket.AF_INET)) as sock:
                    sock.settimeout(3)
                    sock.connect(address)
                    if proxied: assert sock.selected_alpn_protocol() == 'h2'
                    h2 = H2Connection()
                    h2.initiate_connection()
                    sock.sendall(h2.data_to_send())
                    def begin(stream, timeout, body=None, delayed=False, wire=None, extra=()):
                        headers = [(':method', 'POST'), (':scheme', 'https' if proxied else 'http'), (':authority', 'localhost'), (':path', '/unary.Greeter/Greet'), ('content-type', 'application/grpc'), ('te', 'trailers')]
                        headers.extend(extra)
                        if timeout is not None: headers.append(('grpc-timeout', timeout))
                        if delayed: headers.append(("x-delay-before-timeout", "yes"))
                        h2.send_headers(stream, headers)
                        if body is not None: wire = b'\0'+struct.pack('>I',len(body))+body
                        if wire is not None: h2.send_data(stream, wire, end_stream=True)
                        sock.sendall(h2.data_to_send())
                    def log_text():
                        return os.pread(errors.fileno(), 1 << 20, 0).decode()
                    def started(name):
                        end = time.monotonic() + 3
                        while '[INFO] started-' + name not in log_text():
                            assert time.monotonic() < end, 'handler did not start: ' + name
                            time.sleep(.005)
                    def no_forbidden_work():
                        text = log_text()
                        assert 'forbidden-' not in text and 'Roc crashed:' not in text, text
                    def error_response(stream, expected=b'4', message=b'deadline%20exceeded'):
                        status = None
                        http_status = None
                        while True:
                            packet = sock.recv(65536)
                            assert packet, "unexpected connection close"
                            for event in h2.receive_data(packet):
                                if getattr(event, 'stream_id', None) != stream:
                                    continue
                                assert not isinstance(event, StreamReset), event
                                if isinstance(event, ResponseReceived):
                                    http_status = dict(event.headers).get(b':status')
                                if isinstance(event, TrailersReceived):
                                    status = dict(event.headers).get(b'grpc-status')
                                    if message is not None: assert dict(event.headers).get(b'grpc-message') == message
                                if isinstance(event, DataReceived):
                                    assert not event.data, 'failed RPC returned a message'
                                if isinstance(event, StreamEnded):
                                    assert http_status == b'200' and status == expected, (http_status, status)
                                    # Complete the still-open request half after receiving the error.
                                    if stream in (1, 3) and not h2.streams[stream].closed: h2.end_stream(stream)
                                    sock.sendall(h2.data_to_send())
                                    return
                    # Zero and a finite deadline both expire while input is incomplete.
                    begin(1, '0n')
                    error_response(1)
                    begin(3, '50m')
                    error_response(3)
                    # Deadline expiry and client RST both abandon suspended application work.
                    payload = service_pb2.Greeting(name='must-timeout').SerializeToString()
                    begin(5, '500m', payload)
                    started('must-timeout')
                    error_response(5)
                    begin(7, None, service_pb2.Greeting(name='must-cancel').SerializeToString())
                    started('must-cancel')
                    h2.reset_stream(7)
                    sock.sendall(h2.data_to_send())
                    time.sleep(1.1)
                    no_forbidden_work()
                    assert process.poll() is None, 'cancelled handler resumed'
                    begin(9, '20m', service_pb2.Greeting(name='must-not-start').SerializeToString(), delayed=True)
                    error_response(9)
                    # Zero, one, and two envelopes straddle the Unary cardinality boundary.
                    # A truncated prefix and malformed binary/deadline metadata are rejected.
                    for stream, wire, extra, timeout in (
                        (11, b'', (), None),
                        (13, b'\0' * 10, (), None),
                        (15, b'\0' * 4, (), None),
                        (17, b'\0' * 5, (('x-bin', '!'),), None),
                        (19, b'\0' * 5, (), 'invalid'),
                    ):
                        begin(stream, timeout, wire=wire, extra=extra)
                        error_response(stream, expected=b'3', message=None)
                    begin(21, None, service_pb2.Greeting(name='after').SerializeToString())
                    output = b''
                    status = None
                    done = False
                    while not done:
                        packet = sock.recv(65536)
                        assert packet, "unexpected connection close"
                        for event in h2.receive_data(packet):
                            assert not isinstance(event, StreamReset), event
                            if isinstance(event, TrailersReceived):
                                assert event.stream_id == 21
                                status = dict(event.headers).get(b'grpc-status')
                            if isinstance(event, DataReceived):
                                assert event.stream_id == 21
                                output += event.data
                                h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                            if isinstance(event, StreamEnded) and event.stream_id == 21: done = True
                    assert status == b'0', status
                    assert output[0] == 0 and int.from_bytes(output[1:5], 'big') == len(output)-5
                    assert service_pb2.ReplyText.FromString(output[5:]).greeting == 'Hello after'
                    no_forbidden_work()
                assert stop(process) == 0
                no_forbidden_work()
            except BaseException:
                stop(process)
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                process.stdout.close()
    print('PASS typed Unary ' + ('TLS proxy -> ' if proxied else 'direct ') + ('Unix' if unix else 'TCP'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)

    verify(executable, False, proxied=True)
    verify(executable, True, proxied=True)
