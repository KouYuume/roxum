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

    def test_optional_scalar_descriptors(self):
        for kind in {1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 15, 16, 17, 18}:
            with self.subTest(kind=kind):
                req, _, message, field = request()
                # Synthetic names are descriptor metadata, not Roc identifiers.
                message.oneof_decl.add(name='_count')
                field.type, field.proto3_optional, field.oneof_index = kind, True, 0
                result = g.generate(req)
                self.assertFalse(result.error, result.error)
                self.assertEqual(result.supported_features, g.p.CodeGeneratorResponse.FEATURE_PROTO3_OPTIONAL)
                self.assertEqual(result.SerializeToString(), g.generate(req).SerializeToString())

    def test_invalid_optional_metadata(self):
        def optional(mutate):
            def apply(req, file, message, field):
                message.oneof_decl.add(name='_count')
                field.proto3_optional, field.oneof_index = True, 0
                mutate(req, file, message, field)
            self.reject(apply)

        for index in [-1, 1, 2]:
            optional(lambda r, f, m, x: setattr(x, 'oneof_index', index))
        for mutate in [lambda r, f, m, x: x.ClearField('oneof_index'),
                       lambda r, f, m, x: setattr(x, 'proto3_optional', False),
                       lambda r, f, m, x: m.ClearField('oneof_decl'),
                       lambda r, f, m, x: m.oneof_decl.add(name='_unused'),
                       lambda r, f, m, x: m.field.add(name='second', number=2, type=4, label=1, oneof_index=0, proto3_optional=True),
                       lambda r, f, m, x: m.field.add(name='second', number=2, type=4, label=1, oneof_index=0),
                       lambda r, f, m, x: setattr(m.oneof_decl[0], 'name', ''),
                       lambda r, f, m, x: m.oneof_decl[0].options.ParseFromString(b'\x80\x80\x04\x01'),
                       lambda r, f, m, x: setattr(x, 'label', 3),
                       lambda r, f, m, x: setattr(x, 'type', 11)]:
            optional(mutate)

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
                ('message Bad { repeated uint64 value = 1; }', b'invalid.proto:.Bad.value:'),
                ('message Bad { Bad child = 1; }', b'invalid.proto:.Bad:'),
                # The diagnostic must identify the cycle, not its acyclic ancestor.
                ('message Ancestor { Left child = 1; } message Left { Right child = 1; } '
                 'message Right { Left child = 1; }', b'invalid.proto:.Left:'),
                ('message Bad { oneof choice { uint64 value = 1; } }', b'invalid.proto:.Bad.choice:'),
                ('message Builtin { uint64 value = 1; }', b'invalid.proto:.Builtin:'),
                ('message BUILTIN { uint64 value = 1; }', b'invalid.proto:.BUILTIN:')]:
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

    def test_nested_identities_and_deterministic_output(self):
        req, file, message, _ = request()
        file.package = 'example.v1'
        nested = message.nested_type.add(name='Payload')
        nested.oneof_decl.add(name='_text')
        nested.field.add(name='text', number=1, type=9, label=1,
                         proto3_optional=True, oneof_index=0)
        nested.nested_type.add(name='Empty')
        imported = req.proto_file.add(name='other.proto', syntax='proto3', package='other')
        imported.message_type.add(name='Record')
        file.dependency.append('other.proto')
        file.public_dependency.append(0)
        req.file_to_generate.append('other.proto')
        first = g.generate(req)
        self.assertFalse(first.error, first.error)
        self.assertEqual([f.name for f in first.file],
                         ['Record.roc', 'Sample.roc', 'SamplePayload.roc', 'SamplePayloadEmpty.roc', 'main.roc'])
        self.assertIn('# Protobuf message: .example.v1.Sample.Payload', first.file[2].content)
        self.assertIn('SamplePayload :=', first.file[2].content)
        req.file_to_generate.reverse()
        req.proto_file.reverse()
        self.assertEqual(first.SerializeToString(), g.generate(req).SerializeToString())

    def test_identity_collisions_and_invalid_nested_declarations(self):
        def collision(package, name, diagnostic):
            req, file, message, _ = request()
            file.package = 'first'
            message.nested_type.add(name='Child')
            other = req.proto_file.add(name='other.proto', syntax='proto3', package=package)
            other.message_type.add(name=name)
            req.file_to_generate.append('other.proto')
            result = g.generate(req)
            self.assertIn(diagnostic, result.error)
            self.assertFalse(result.file)
        collision('first', 'Sample', 'duplicate message identity')
        collision('second', 'Sample', 'module name collision')
        collision('second', 'SAMPLE', 'module name collision')
        collision('second', 'SampleChild', 'module name collision')
        for package in ['.pkg', 'pkg.', 'pkg..name', '9pkg', 'pkg/name']:
            self.reject(lambda r, f, m, x: setattr(f, 'package', package))
        for mutate in [lambda n: n.field.add(name='value', number=1, type=11, label=1, type_name='.Missing'),
                       lambda n: n.field.add(name='value', number=1, type=4, label=3),
                       lambda n: n.enum_type.add(name='Choice'),
                       lambda n: setattr(n.options, 'map_entry', True),
                       lambda n: setattr(n, 'name', 'bad_name')]:
            self.reject(lambda r, f, m, x: mutate(m.nested_type.add(name='Child')))

    def test_import_closure_and_rejections(self):
        def imported_request():
            req, file, _, _ = request()
            # A diamond import graph exercises shared and transitive dependencies.
            for name, dependencies in [('left', ['leaf']), ('right', ['leaf']), ('leaf', [])]:
                imported = req.proto_file.add(name=name + '.proto', syntax='proto3')
                imported.message_type.add(name=name.title())
                imported.dependency.extend(dep + '.proto' for dep in dependencies)
                req.file_to_generate.append(imported.name)
            file.dependency.extend(['left.proto', 'right.proto'])
            file.public_dependency.append(0)
            return req
        self.assertFalse(g.generate(imported_request()).error)
        cases = [
            (lambda r: r.file_to_generate.remove('leaf.proto'), 'generation target'),
            (lambda r: r.proto_file.pop(), 'missing descriptor'),
            (lambda r: r.proto_file[0].dependency.append('missing.proto'), 'missing import descriptor'),
            (lambda r: r.proto_file[0].dependency.append('left.proto'), 'duplicate imports'),
            (lambda r: r.proto_file[0].weak_dependency.append(0), 'weak imports'),
            (lambda r: r.proto_file[0].public_dependency.append(0), 'public import indices'),
            (lambda r: r.proto_file[-1].dependency.append('test.proto'), 'cyclic imports'),
            (lambda r: r.proto_file[0].dependency.append('test.proto'), 'cyclic imports'),
            (lambda r: r.proto_file[-1].enum_type.add(name='Choice'), 'enums and extensions'),
        ]
        # Public indices immediately below, at, and above the valid upper bound.
        for index in [-1, 1, 2, 3]:
            req = imported_request()
            req.proto_file[0].public_dependency[:] = [index]
            result = g.generate(req)
            self.assertEqual(bool(result.error), index != 1)
            if result.error:
                self.assertFalse(result.file)
        for mutate, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic):
                req = imported_request()
                mutate(req)
                result = g.generate(req)
                self.assertIn(diagnostic, result.error)
                self.assertFalse(result.file)

    def test_import_only_files_and_empty_requests(self):
        req, file, _, _ = request()
        file.dependency.append('services.proto')
        services = req.proto_file.add(name='services.proto', syntax='proto3')
        services.service.add(name='Ignored')
        req.file_to_generate.append(services.name)
        self.assertFalse(g.generate(req).error)
        file.ClearField('message_type')
        result = g.generate(req)
        self.assertIn('no messages requested', result.error)
        self.assertFalse(result.file)
        req.ClearField('file_to_generate')
        result = g.generate(req)
        self.assertIn('no files requested', result.error)
        self.assertFalse(result.file)

    def test_protoc_import_targets_and_collisions(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            (base / 'leaf.proto').write_text('syntax = "proto3"; package other; message Leaf { optional string text = 1; }')
            (base / 'root.proto').write_text('syntax = "proto3"; package example; import public "leaf.proto"; message Root { message Child {} }')
            output = base / 'output'
            output.mkdir()
            command = [str(root / 'zig-out/protobuf-codegen/bin/protoc'), '-I', directory,
                       '--plugin=protoc-gen-roc=' + str(root / 'tools/protoc-gen-roc/protoc-gen-roc'),
                       '--roc_out=wire=./wire/main.roc:' + str(output)]
            missing = subprocess.run(command + ['root.proto'], capture_output=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn(b'leaf.proto must also be listed as a generation target', missing.stderr)
            self.assertEqual(list(output.iterdir()), [])
            subprocess.run(command + ['root.proto', 'leaf.proto'], capture_output=True, check=True)
            self.assertEqual({f.name for f in output.iterdir()}, {'Root.roc', 'RootChild.roc', 'Leaf.roc', 'main.roc'})
            for file in output.iterdir():
                file.unlink()
            with (base / 'root.proto').open('a') as file:
                file.write(' message RootChild {}')
            collision = subprocess.run(command + ['root.proto', 'leaf.proto'], capture_output=True)
            self.assertNotEqual(collision.returncode, 0)
            self.assertIn(b'module name collision', collision.stderr)
            self.assertEqual(list(output.iterdir()), [])

    def test_message_references(self):
        req, file, message, field = request()
        child = message.nested_type.add(name='Child')
        child.field.add(name='value', number=1, type=4, label=1)
        field.type, field.type_name = 11, '.Sample.Child'
        self.assertFalse(g.generate(req).error)
        for target in ['', 'Sample.Child', '.Missing', '.Sample']:
            field.type_name = target
            result = g.generate(req)
            self.assertTrue(result.error, target)
            self.assertFalse(result.file)
        field.type_name = '.Sample.Child'
        child.field[0].type, child.field[0].type_name = 11, '.Sample'
        self.assertIn('recursive', g.generate(req).error)
        req, file, message, field = request()
        other = req.proto_file.add(name='other.proto', syntax='proto3')
        other.message_type.add(name='Other')
        req.file_to_generate.append('other.proto')
        field.type, field.type_name = 11, '.Other'
        self.assertIn('not visible', g.generate(req).error)
        file.dependency.append('other.proto')
        self.assertFalse(g.generate(req).error)
        # A transitive import exposes types only when the intermediate edge is public.
        leaf = req.proto_file.add(name='leaf.proto', syntax='proto3')
        leaf.message_type.add(name='Leaf')
        req.file_to_generate.append('leaf.proto')
        other.dependency.append('leaf.proto')
        field.type_name = '.Leaf'
        result = g.generate(req)
        self.assertIn('not visible', result.error)
        self.assertFalse(result.file)
        other.public_dependency.append(0)
        self.assertFalse(g.generate(req).error)

    def test_optional_message_metadata(self):
        def sample():
            req, file, message, field = request()
            file.message_type.add(name='Child')
            field.type, field.type_name = 11, '.Child'
            return req, message, field

        req, message, field = sample()
        ordinary = g.generate(req)
        self.assertFalse(ordinary.error)
        message.oneof_decl.add(name='_count')
        field.proto3_optional, field.oneof_index = True, 0
        explicit = g.generate(req)
        self.assertFalse(explicit.error)
        self.assertEqual(ordinary.SerializeToString(), explicit.SerializeToString())
        # Optional metadata must not bypass oneof, reference, or cycle validation.
        for mutate in [lambda m, f: f.ClearField('oneof_index'),
                       lambda m, f: setattr(f, 'oneof_index', -1),
                       lambda m, f: setattr(f, 'oneof_index', 1),
                       lambda m, f: setattr(f, 'proto3_optional', False),
                       lambda m, f: setattr(f, 'type_name', '.Missing'),
                       lambda m, f: setattr(f, 'type_name', '.Sample'),
                       lambda m, f: m.field.add(name='other', number=2, type=11,
                                               label=1, type_name='.Child', oneof_index=0)]:
            req, message, field = sample()
            message.oneof_decl.add(name='_count')
            field.proto3_optional, field.oneof_index = True, 0
            mutate(message, field)
            result = g.generate(req)
            self.assertTrue(result.error)
            self.assertFalse(result.file)

    def test_repeated_length_fields(self):
        # Numeric, enum, and group lists remain unsupported.
        for kind in set(range(1, 19)) - {9, 12, 11}:
            req, file, _, field = request()
            field.type, field.label = kind, 3
            result = g.generate(req)
            self.assertTrue(result.error)
            self.assertFalse(result.file)
        for kind in [9, 12, 11]:
            req, file, _, field = request()
            field.type, field.label = kind, 3
            if kind == 11:
                file.message_type.add(name='Child')
                field.type_name = '.Child'
            self.assertFalse(g.generate(req).error)
            for mutate in [lambda f: setattr(f, 'proto3_optional', True),
                           lambda f: setattr(f, 'oneof_index', 0),
                           lambda f: setattr(f.options, 'packed', True),
                           lambda f: setattr(f.options, 'packed', False)]:
                req, file, _, field = request()
                field.type, field.label = kind, 3
                if kind == 11:
                    file.message_type.add(name='Child')
                    field.type_name = '.Child'
                mutate(field)
                result = g.generate(req)
                self.assertTrue(result.error)
                self.assertFalse(result.file)

    def test_repeated_message_cycles(self):
        req, _, message, field = request()
        field.type, field.label, field.type_name = 11, 3, '.Sample'
        result = g.generate(req)
        self.assertIn('recursive', result.error)
        self.assertFalse(result.file)
        child = message.nested_type.add(name='Child')
        field.type_name = '.Sample.Child'
        child.field.add(name='parent', number=1, type=11, label=3, type_name='.Sample')
        result = g.generate(req)
        self.assertIn('recursive', result.error)
        self.assertFalse(result.file)

    def test_plugin_error_protocol(self):
        output = subprocess.run([sys.executable, g.__file__], input=b'\x80', capture_output=True, check=True)
        response = g.p.CodeGeneratorResponse.FromString(output.stdout)
        self.assertEqual(response.error, 'invalid CodeGeneratorRequest')
        self.assertFalse(response.file)
        self.assertFalse(output.stderr)


if __name__ == '__main__':
    unittest.main()
