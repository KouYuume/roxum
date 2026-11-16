"""Typed Unary interoperability using protoc-generated Python messages and grpcio."""
import os
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop


def verify(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-unary-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'rpc.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\n')
        with tempfile.TemporaryFile(mode='w+') as errors:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timed out'
                endpoint = process.stdout.readline().strip()
                target = endpoint if unix else f'127.0.0.1:{int(endpoint)}'
                with grpc.insecure_channel(target) as channel:
                    grpc.channel_ready_future(channel).result(timeout=10)
                    call = channel.unary_unary('/unary.Greeter/Greet', request_serializer=service_pb2.Greeting.SerializeToString, response_deserializer=service_pb2.ReplyText.FromString)
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
                with socket.socket(socket.AF_UNIX if unix else socket.AF_INET) as sock:
                    sock.settimeout(3)
                    sock.connect(path if unix else ('127.0.0.1', int(endpoint)))
                    h2 = H2Connection()
                    h2.initiate_connection()
                    sock.sendall(h2.data_to_send())
                    def begin(stream, timeout, body=None, delayed=False):
                        headers = [(':method', 'POST'), (':scheme', 'http'), (':authority', 'localhost'), (':path', '/unary.Greeter/Greet'), ('content-type', 'application/grpc'), ('te', 'trailers')]
                        if timeout is not None: headers.append(('grpc-timeout', timeout))
                        if delayed: headers.append(("x-delay-before-timeout", "yes"))
                        h2.send_headers(stream, headers)
                        if body is not None: h2.send_data(stream, b'\0'+struct.pack('>I',len(body))+body,end_stream=True)
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
                    def deadline_response(stream):
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
                                    assert dict(event.headers).get(b'grpc-message') == b'deadline%20exceeded'
                                if isinstance(event, DataReceived):
                                    assert not event.data, 'expired RPC returned a message'
                                if isinstance(event, StreamEnded):
                                    assert http_status == b'200' and status == b'4', (http_status, status)
                                    # Complete the still-open request half after receiving the error.
                                    if stream in (1, 3): h2.end_stream(stream)
                                    sock.sendall(h2.data_to_send())
                                    return
                    # Zero and a finite deadline both expire while input is incomplete.
                    begin(1, '0n')
                    deadline_response(1)
                    begin(3, '50m')
                    deadline_response(3)
                    # Deadline expiry and client RST both abandon suspended application work.
                    payload = service_pb2.Greeting(name='must-timeout').SerializeToString()
                    begin(5, '500m', payload)
                    started('must-timeout')
                    deadline_response(5)
                    begin(7, None, service_pb2.Greeting(name='must-cancel').SerializeToString())
                    started('must-cancel')
                    h2.reset_stream(7)
                    sock.sendall(h2.data_to_send())
                    time.sleep(1.1)
                    no_forbidden_work()
                    assert process.poll() is None, 'cancelled handler resumed'
                    begin(9, '20m', service_pb2.Greeting(name='must-not-start').SerializeToString(), delayed=True)
                    deadline_response(9)
                    begin(11, None, service_pb2.Greeting(name='after').SerializeToString())
                    output = b''
                    status = None
                    done = False
                    while not done:
                        packet = sock.recv(65536)
                        assert packet, "unexpected connection close"
                        for event in h2.receive_data(packet):
                            assert not isinstance(event, StreamReset), event
                            if isinstance(event, TrailersReceived):
                                assert event.stream_id == 11
                                status = dict(event.headers).get(b'grpc-status')
                            if isinstance(event, DataReceived):
                                assert event.stream_id == 11
                                output += event.data
                                h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                            if isinstance(event, StreamEnded) and event.stream_id == 11: done = True
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
    print('PASS typed Unary ' + ('Unix' if unix else 'TCP'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)
