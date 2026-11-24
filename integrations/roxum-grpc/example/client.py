"""Call the example using generated messages and a generated grpcio service stub."""
import argparse
from pathlib import Path
import sys
import threading


def verify(target, bindings):
    sys.path.insert(0, str(bindings))
    import grpc
    import service_pb2
    import service_pb2_grpc
    with grpc.insecure_channel(target, options=(('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0))) as channel:
        greeter = service_pb2_grpc.GreeterStub(channel)
        call = greeter.Greet
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
        stream = greeter.Watch(service_pb2.Greeting(name='Roc'), timeout=5)
        assert [reply.greeting for reply in stream] == ['Hello Roc 0', 'Hello Roc 1', 'Hello Roc 2']
        assert stream.code() == grpc.StatusCode.OK
        for names_to_count in ((), ('Ada', 'Roc')):
            greetings = (service_pb2.Greeting(name=name) for name in names_to_count)
            reply, completed = greeter.CountGreetings.with_call(greetings, timeout=5)
            assert reply.greeting == str(len(names_to_count))
            assert completed.code() == grpc.StatusCode.OK
        first_reply = threading.Event()
        def names():
            yield service_pb2.Greeting(name='Ada')
            if first_reply.wait(5):
                yield service_pb2.Greeting(name='Roc')

        conversation = greeter.Converse(names(), timeout=10)
        try:
            assert next(conversation).greeting == 'Hello Ada'
            first_reply.set()
            assert [reply.greeting for reply in conversation] == ['Hello Roc']
            assert conversation.code() == grpc.StatusCode.OK
        finally:
            first_reply.set()
            conversation.cancel()
    print('PASS generated greetings across all four RPC forms')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='127.0.0.1:<printed server port>')
    parser.add_argument('--bindings', type=Path, default=(Path(__file__).resolve().parent / '../../../zig-out/grpc-example').resolve())
    args = parser.parse_args()
    verify(args.target, args.bindings)
