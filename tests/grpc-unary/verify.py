"""Typed Unary interoperability using protoc-generated Python messages and grpcio."""
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
                assert stop(process) == 0
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
