"""Independent gRPC client against fixed Roc message envelopes and trailers."""
import json
import pathlib
import select
import subprocess
import sys
import tempfile

import grpc

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop


# Protobuf field 1, wire type 2, five UTF-8 bytes. gRPC supplies the envelope.
REQUEST = b'\x0a\x05hello'
RESPONSE = b'\x0a\x05world'


def verify(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-', dir='/tmp') as directory:
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
                if unix:
                    assert endpoint == 'unix:' + path, endpoint
                    target = endpoint
                else:
                    target = f'127.0.0.1:{int(endpoint)}'
                with grpc.insecure_channel(target, options=(('grpc.enable_retries', 0),)) as channel:
                    grpc.channel_ready_future(channel).result(timeout=10)

                    def call(method, payload=REQUEST):
                        return channel.unary_unary('/probe.Echo/' + method).with_call(payload, timeout=5)

                    def success(method, payload, expected):
                        response, completed = call(method, payload)
                        assert response == expected, response
                        assert completed.code() == grpc.StatusCode.OK, completed.code()
                        assert dict(completed.trailing_metadata())['probe-result'] == 'complete'

                    success('Say', REQUEST, RESPONSE)
                    # Zero-length serialized message still requires its five-byte envelope.
                    success('Empty', b'', b'')
                    for method, payload, status, details in (
                        ('Reject', REQUEST, grpc.StatusCode.INVALID_ARGUMENT, 'fixed rejection'),
                        ('Say', b'\x0a\x04hell', grpc.StatusCode.INVALID_ARGUMENT, 'fixed rejection'),
                        # Negative controls: HTTP 200 and some bytes are insufficient.
                        ('MissingStatus', REQUEST, grpc.StatusCode.UNKNOWN, None),
                    ):
                        try:
                            call(method, payload)
                        except grpc.RpcError as error:
                            assert error.code() == status, (method, error.code(), error.details())
                            if details is not None:
                                assert error.details() == details, error.details()
                        else:
                            raise AssertionError(f'{method} unexpectedly succeeded')
                        # A failed RPC must not prevent another RPC on this channel.
                        success('Say', REQUEST, RESPONSE)
                    # This client can report OK with no message for a truncated
                    # envelope. The exact response-byte assertion is essential.
                    try:
                        malformed, completed = call('BadLength')
                    except grpc.RpcError as error:
                        assert error.code() == grpc.StatusCode.INTERNAL, error
                    else:
                        assert malformed is None, malformed
                        assert completed.code() == grpc.StatusCode.OK, completed.code()
                    success('Say', REQUEST, RESPONSE)
                assert stop(process) == 0
            except BaseException:
                stop(process)
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                process.stdout.close()
    print('PASS fixed-byte native gRPC ' + ('Unix' if unix else 'TCP'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)
