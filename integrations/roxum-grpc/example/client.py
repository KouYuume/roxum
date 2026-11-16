"""Call the example using generated messages and a generated grpcio service stub."""
import argparse
from pathlib import Path
import sys


def verify(target, bindings):
    sys.path.insert(0, str(bindings))
    import grpc
    import service_pb2
    import service_pb2_grpc
    with grpc.insecure_channel(target, options=(('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0))) as channel:
        call = service_pb2_grpc.GreeterStub(channel).Greet
        response, completed = call.with_call(service_pb2.Greeting(name='Roc'), timeout=5,
                                             metadata=(('request-bin', b'\x00\xff'), ('authorization', 'example-token')))
        assert response.greeting == 'Hello Roc'
        assert ('service', 'greeter') in completed.initial_metadata()
        assert ('request-bin', b'\x00\xff') in completed.trailing_metadata()
        assert not any(name == 'authorization' for name, _ in completed.trailing_metadata())
        try:
            call(service_pb2.Greeting(), timeout=5)
        except grpc.RpcError as error:
            assert error.code() == grpc.StatusCode.INVALID_ARGUMENT
            assert error.details() == 'name is required'
        else:
            raise AssertionError('empty name accepted')
        assert call(service_pb2.Greeting(name='again'), timeout=5).greeting == 'Hello again'
    print('PASS Hello Roc, metadata, INVALID_ARGUMENT and subsequent call')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='127.0.0.1:<printed server port>')
    parser.add_argument('--bindings', type=Path, default=(Path(__file__).resolve().parent / '../../../zig-out/grpc-example').resolve())
    args = parser.parse_args()
    verify(args.target, args.bindings)
