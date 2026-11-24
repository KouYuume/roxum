"""Service descriptor rejection and codec-only independence contracts."""
import pathlib
import sys
import unittest
from google.protobuf.compiler import plugin_pb2

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'tools/protoc-gen-roc'))
import generate


def request():
    value = plugin_pb2.CodeGeneratorRequest(parameter='wire=wire/main.roc,grpc=grpc/main.roc,pf=platform/main.roc')
    value.file_to_generate.append('test.proto')
    file = value.proto_file.add(name='test.proto', syntax='proto3', package='test')
    file.message_type.add(name='Input')
    file.message_type.add(name='Output')
    file.service.add(name='Example').method.add(name='Call', input_type='.test.Input', output_type='.test.Output')
    return value


class Services(unittest.TestCase):
    def test_valid_and_codec_only(self):
        req = request()
        result = generate.generate(req)
        self.assertFalse(result.error)
        binding = next(f.content for f in result.file if f.name == 'ExampleService.roc')
        self.assertIn('model, Input, List(GrpcMetadata.Entry)', binding)
        self.assertIn('GrpcUnary.Response(Output)', binding)
        self.assertIn('Output.encode', binding)
        self.assertIn('.layer(GrpcTimeout.layer(limits.metadata))', binding)
        self.assertIn('ExampleService.roc', [f.name for f in result.file])
        req.parameter = 'wire=wire/main.roc'
        result = generate.generate(req)
        self.assertFalse(result.error)
        self.assertNotIn('ExampleService.roc', [f.name for f in result.file])
        self.assertNotIn('platform', result.file[-1].content)

    def test_handlers_name_collision_is_binding_only(self):
        # Both request and response type references share the generated scope.
        for direction, index in [('input_type', 0), ('output_type', 1)]:
            req = request()
            req.proto_file[0].message_type[index].name = 'Handlers'
            setattr(req.proto_file[0].service[0].method[0], direction, '.test.Handlers')
            result = generate.generate(req)
            self.assertIn('conflicts with a service binding import', result.error)
            self.assertFalse(result.file)
            req.parameter = 'wire=wire/main.roc'
            result = generate.generate(req)
            self.assertFalse(result.error)
            self.assertIn('Handlers.roc', [file.name for file in result.file])

    def test_streaming_import_collision_does_not_change_unary_names(self):
        req = request()
        req.proto_file[0].message_type[0].name = 'GrpcServerStream'
        method = req.proto_file[0].service[0].method[0]
        method.input_type = '.test.GrpcServerStream'
        self.assertFalse(generate.generate(req).error)
        method.server_streaming = True
        result = generate.generate(req)
        self.assertIn('conflicts with a service binding import', result.error)
        self.assertFalse(result.file)

    def test_streaming_forms_and_mixed_limits(self):
        # Unary-only remains unchanged; server-only and mixed services select
        # typed output producers. Client input uses a typed consumer.
        for client, server in ((False, True), (True, False), (True, True)):
            req = request()
            method = req.proto_file[0].service[0].method[0]
            method.client_streaming, method.server_streaming = client, server
            result = generate.generate(req)
            if client and server:
                self.assertFalse(result.error)
                binding = next(f.content for f in result.file if f.name == 'ExampleService.roc')
                self.assertIn('duplex_call : GrpcDuplex.Callbacks(model, state_call, Input, Output)', binding)
                self.assertIn('GrpcDuplex.handler(', binding)
            elif client:
                self.assertFalse(result.error)
                self.assertIn("GrpcClientStream.Consumer(Input, Output)", next(f.content for f in result.file if f.name == "ExampleService.roc"))
            else:
                self.assertFalse(result.error)
                binding = next(f.content for f in result.file if f.name == 'ExampleService.roc')
                self.assertIn('GrpcServerStream.Response(Output)', binding)
                self.assertIn('GrpcServerStream.Limits', binding)
                self.assertIn('GrpcTimeout.streaming_layer(limits)', binding)
                req.proto_file[0].service[0].method.add(name='Unary', input_type='.test.Input', output_type='.test.Output')
                mixed = generate.generate(req)
                self.assertFalse(mixed.error)
                binding = next(f.content for f in mixed.file if f.name == 'ExampleService.roc')
                self.assertIn('limits.streaming', binding)
                self.assertIn('limits.unary', binding)

    def test_method_collisions_follow_rpc_names_and_handler_fields(self):
        req = request()
        methods = req.proto_file[0].service[0].method
        duplex = methods.add(name='CALL', input_type='.test.Input', output_type='.test.Output',
                             client_streaming=True, server_streaming=True)
        result = generate.generate(req)
        self.assertFalse(result.error)
        binding = next(f.content for f in result.file if f.name == 'ExampleService.roc')
        self.assertIn('"/test.Example/Call", MethodRouter.post(GrpcUnary.handler', binding)
        self.assertIn('"/test.Example/CALL", MethodRouter.post(GrpcDuplex.handler', binding)
        self.assertIn('handlers.call_call!', binding)
        self.assertIn('handlers.duplex_call', binding)

        # Reject duplicate routes even in a hand-built descriptor.
        duplex.name = 'Call'
        result = generate.generate(req)
        self.assertIn('method binding name collision', result.error)
        self.assertFalse(result.file)

        # Distinct routes still cannot share a generated duplex callback field.
        duplex.name = 'CALL'
        methods[0].client_streaming = methods[0].server_streaming = True
        result = generate.generate(req)
        self.assertIn('method binding name collision', result.error)
        self.assertFalse(result.file)

    def test_bidirectional_methods_have_independent_state(self):
        req = request()
        file = req.proto_file[0]
        methods = file.service[0].method
        for name in ('Chat', 'Subscribe'):
            methods.add(name=name, input_type='.test.Input', output_type='.test.Output',
                        client_streaming=True, server_streaming=True)
        result = generate.generate(req)
        self.assertFalse(result.error)
        binding = next(f.content for f in result.file if f.name == 'ExampleService.roc')
        self.assertIn('Handlers(model, state_chat, state_subscribe)', binding)
        for name in ('chat', 'subscribe'):
            self.assertIn(f'duplex_{name} : GrpcDuplex.Callbacks(model, state_{name}, Input, Output)', binding)
        self.assertEqual(binding.count('GrpcTimeout.streaming_layer(limits.streaming)'), 2)
        self.assertIn('GrpcTimeout.layer(limits.unary.metadata)', binding)

        file.message_type.add(name='GrpcDuplex')
        result = generate.generate(req)
        self.assertIn('conflicts with a service binding import', result.error)
        self.assertFalse(result.file)
        req.parameter = 'wire=wire/main.roc'
        self.assertFalse(generate.generate(req).error)

    def test_rejected_descriptors_are_atomic(self):
        mutations = [
            lambda f: setattr(f.service[0].method[0], 'input_type', '.test.Missing'),
            lambda f: setattr(f.service[0].method[0], 'output_type', '.test.Missing'),
            lambda f: f.message_type.add(name='ExampleService'),
            lambda f: f.service[0].method.add(name='CALL', input_type='.test.Input', output_type='.test.Output'),
            lambda f: setattr(f.service[0].options, 'deprecated', True),
            lambda f: setattr(f.service[0].method[0].options, 'deprecated', True),
        ]
        for mutate in mutations:
            req = request()
            mutate(req.proto_file[0])
            result = generate.generate(req)
            self.assertTrue(result.error)
            self.assertFalse(result.file)


if __name__ == '__main__':
    unittest.main()
