"""Descriptor contract tests; protoc normally rejects structurally invalid input first."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'tools/protoc-gen-roc'))
import generate as g


def request():
    req = g.p.CodeGeneratorRequest(parameter='wire=../../../libraries/roc-protobuf/package/main.roc', file_to_generate=['test.proto'])
    file = req.proto_file.add(name='test.proto', syntax='proto3')
    message = file.message_type.add(name='Sample')
    message.field.add(name='count', number=1, type=4, label=1)
    return req, file, message, message.field[0]


class Generator(unittest.TestCase):
    def reject(self, mutate):
        req, file, message, field = request()
        mutate(req, file, message, field)
        result = g.generate(req)
        self.assertTrue(result.error)
        self.assertFalse(result.file, 'errors must not return partial output')
        self.assertIn(':', result.error)

    def test_supported_types_and_number_boundaries(self):
        # The advertised proto3 scalar set is independent of the generator table.
        scalar_types = {1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 15, 16, 17, 18}
        self.assertEqual(set(g.SCALARS), scalar_types)
        for kind in scalar_types:
            for number in [1, 15, 16, 17, 18999, 20000, 20001, 536870910, 536870911]:
                with self.subTest(kind=kind, number=number):
                    req, _, _, f = request()
                    f.type, f.number = kind, number
                    self.assertFalse(g.generate(req).error)
        for number in [0, 19000, 19001, 19998, 19999, 536870912]:
            self.reject(lambda r, f, m, x: setattr(x, 'number', number))

    def test_unsupported_field_contracts(self):
        for kind in range(1, 19):
            if kind not in g.SCALARS:
                self.reject(lambda r, f, m, x: setattr(x, 'type', kind))
        for attribute, value in [('label', 2), ('label', 3), ('proto3_optional', True),
                                 ('oneof_index', 0), ('default_value', '0'),
                                 ('type_name', '.Other'), ('extendee', '.Other')]:
            self.reject(lambda r, f, m, x: setattr(x, attribute, value))
        for name in g.KEYWORDS | {'Bad', '_bad', 'bad__name', 'bad_', 'é', 'x/y'}:
            self.reject(lambda r, f, m, x: setattr(x, 'name', name))
        self.reject(lambda r, f, m, x: m.field.add().CopyFrom(x))
        self.reject(lambda r, f, m, x: setattr(x.options, 'packed', False))

    def test_unsupported_declarations(self):
        for syntax in ['', 'proto2', 'editions']:
            self.reject(lambda r, f, m, x: setattr(f, 'syntax', syntax))
        for mutate in [lambda r, f, m, x: f.dependency.append('other.proto'),
                       lambda r, f, m, x: f.enum_type.add(name='Enum'),
                       lambda r, f, m, x: f.extension.add(name='extension'),
                       lambda r, f, m, x: m.nested_type.add(name='Nested'),
                       lambda r, f, m, x: m.enum_type.add(name='Enum'),
                       lambda r, f, m, x: m.oneof_decl.add(name='choice'),
                       lambda r, f, m, x: m.extension_range.add(start=1, end=2),
                       lambda r, f, m, x: setattr(m.options, 'map_entry', True),
                       lambda r, f, m, x: setattr(f.options, 'java_package', 'pkg'),
                       lambda r, f, m, x: x.options.ParseFromString(b'\x80\x80\x04\x01')]:
            self.reject(mutate)

    def test_names_parameters_and_atomicity(self):
        for name in g.RESERVED | {'../Evil', 'foo', 'Foo_Bar', 'MAIN', 'Main', 'Builtin', 'BUILTIN'}:
            self.reject(lambda r, f, m, x: setattr(m, 'name', name))
        self.reject(lambda r, f, m, x: f.message_type.add(name='SAMPLE'))
        self.reject(lambda r, f, m, x: r.file_to_generate.append('missing.proto'))
        self.reject(lambda r, f, m, x: r.file_to_generate.append('test.proto'))
        self.reject(lambda r, f, m, x: r.proto_file.add().CopyFrom(f))
        for param in ['', 'wire=', 'wire="evil"', 'wire=${evil}', 'wire=a\nb', 'wire=a,foo=b']:
            self.reject(lambda r, f, m, x: setattr(r, 'parameter', param))

    def test_empty_services_determinism(self):
        req, file, message, _ = request()
        message.ClearField('field')
        file.service.add(name='Ignored')
        first = g.generate(req)
        self.assertFalse(first.error)
        self.assertEqual(first.SerializeToString(), g.generate(req).SerializeToString())
        self.assertEqual([f.name for f in first.file], ['Sample.roc', 'main.roc'])

    def test_protoc_rejects_without_partial_output(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        # Valid messages preceding an unsupported declaration must not be emitted.
        for declaration, diagnostic in [
                ('message Bad { repeated uint64 value = 1; }', b'invalid.proto:Bad.value:'),
                ('message Builtin { uint64 value = 1; }', b'invalid.proto:Builtin:'),
                ('message BUILTIN { uint64 value = 1; }', b'invalid.proto:BUILTIN:')]:
            with self.subTest(declaration=declaration), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                schema = base / 'invalid.proto'
                schema.write_text('syntax = "proto3"; message Good { uint64 value = 1; } ' + declaration)
                output = base / 'output'
                output.mkdir()
                result = subprocess.run([str(root / 'zig-out/protobuf-codegen/bin/protoc'),
                                         '-I', directory,
                                         '--plugin=protoc-gen-roc=' + str(root / 'tools/protoc-gen-roc/protoc-gen-roc'),
                                         '--roc_out=wire=./wire/main.roc:' + str(output), str(schema)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(list(output.iterdir()), [])

    def test_plugin_error_protocol(self):
        output = subprocess.run([sys.executable, g.__file__], input=b'\x80', capture_output=True, check=True)
        response = g.p.CodeGeneratorResponse.FromString(output.stdout)
        self.assertEqual(response.error, 'invalid CodeGeneratorRequest')
        self.assertFalse(response.file)
        self.assertFalse(output.stderr)


if __name__ == '__main__':
    unittest.main()
