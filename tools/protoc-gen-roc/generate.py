"""Strict scalar pilot of the protoc plugin protocol. No roxum runtime dependency."""
import re
import sys
from google.protobuf import descriptor_pb2 as d
from google.protobuf.compiler import plugin_pb2 as p
from google.protobuf.message import DecodeError

# Roc type, wire tag, primitive suffix, default expression.
SCALARS = {
    d.FieldDescriptorProto.TYPE_STRING: ('Str', 'Bytes', 'string', '""'),
    d.FieldDescriptorProto.TYPE_DOUBLE: ('F64', 'Fixed64', 'double', '0.0.F64'),
    d.FieldDescriptorProto.TYPE_FLOAT: ('F32', 'Fixed32', 'float', '0.0.F32'),
    d.FieldDescriptorProto.TYPE_BOOL: ('Bool', 'Varint', 'bool', 'Bool.False'),
    d.FieldDescriptorProto.TYPE_SFIXED64: ('I64', 'Fixed64', 'sfixed64', '0.I64'),
    d.FieldDescriptorProto.TYPE_SFIXED32: ('I32', 'Fixed32', 'sfixed32', '0.I32'),
    d.FieldDescriptorProto.TYPE_SINT64: ('I64', 'Varint', 'sint64', '0.I64'),
    d.FieldDescriptorProto.TYPE_SINT32: ('I32', 'Varint', 'sint32', '0.I32'),
    d.FieldDescriptorProto.TYPE_INT64: ('I64', 'Varint', 'int64', '0.I64'),
    d.FieldDescriptorProto.TYPE_INT32: ('I32', 'Varint', 'int32', '0.I32'),
    d.FieldDescriptorProto.TYPE_UINT32: ('U32', 'Varint', 'uint32', '0.U32'),
    d.FieldDescriptorProto.TYPE_UINT64: ('U64', 'Varint', 'varint', '0.U64'),
    d.FieldDescriptorProto.TYPE_FIXED32: ('U32', 'Fixed32', 'fixed32', '0.U32'),
    d.FieldDescriptorProto.TYPE_FIXED64: ('U64', 'Fixed64', 'fixed64', '0.U64'),
    d.FieldDescriptorProto.TYPE_BYTES: ('List(U8)', 'Bytes', 'bytes', '[]'),
}
WIRE_TYPES = {d.FieldDescriptorProto.TYPE_UINT64, d.FieldDescriptorProto.TYPE_FIXED32,
              d.FieldDescriptorProto.TYPE_FIXED64, d.FieldDescriptorProto.TYPE_BYTES}
FLOAT_TYPES = {d.FieldDescriptorProto.TYPE_FLOAT, d.FieldDescriptorProto.TYPE_DOUBLE}
KEYWORDS = set('app package platform provides exposes imports import as if then else match when is expect dbg crash return var for in while and or not where type alias implements with exposing generates has hosted interface module packages requires targets break'.split())
RESERVED = {'Builtin', 'ProtobufScalar', 'ProtobufWire', 'List', 'Try', 'U64', 'U32', 'U8', 'Bool', 'Str', 'Main', 'Box', 'Dec', 'F32', 'F64', 'I8', 'I16', 'I32', 'I64', 'I128', 'U16', 'U128', 'Set', 'Dict'}


def require(condition, location, reason):
    if not condition:
        raise ValueError(f'{location}: {reason}')


def validate(request):
    require(re.fullmatch(r'wire=[A-Za-z0-9_./:-]+', request.parameter), 'parameter',
            'expected wire=<Roc package path>; only letters, digits, _, ., /, :, - are accepted')
    files = {f.name: f for f in request.proto_file}
    require(len(files) == len(request.proto_file), 'request', 'duplicate file descriptors')
    require(request.file_to_generate, 'request', 'no files requested')
    require(len(set(request.file_to_generate)) == len(request.file_to_generate), 'request', 'duplicate generation targets')
    names = set()
    messages = []
    for filename in request.file_to_generate:
        require(filename in files, filename, 'missing descriptor')
        file = files[filename]
        require(file.syntax == 'proto3', filename, 'only proto3 is supported')
        require(not file.dependency, filename, 'imports are not supported')
        require(not file.enum_type and not file.extension, filename, 'enums and extensions are not supported')
        require(not file.options.SerializeToString() and not file.HasField('edition'), filename, 'file options and editions are not supported')
        for message in file.message_type:
            loc = f'{filename}:{message.name}'
            name = message.name
            require(re.fullmatch(r'[A-Z][A-Za-z0-9]*', name) and name.lower() not in {n.lower() for n in RESERVED},
                    loc, 'message name is not a supported Roc type name')
            require(name.lower() not in names, loc, 'message module name collision')
            names.add(name.lower())
            require(not message.nested_type and not message.enum_type
                    and not message.extension and not message.extension_range,
                    loc, 'nested types, enums, and extensions are not supported')
            require(not message.options.SerializeToString(), loc, 'message options are not supported')
            oneof_names = set()
            for index, oneof in enumerate(message.oneof_decl):
                where = loc + '.' + oneof.name
                require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', oneof.name)
                        and oneof.name not in oneof_names, where, 'invalid or duplicate oneof name')
                oneof_names.add(oneof.name)
                members = [f for f in message.field if f.HasField('oneof_index') and f.oneof_index == index]
                require(len(members) == 1 and members[0].proto3_optional, where,
                        'only synthetic oneofs for proto3 optional scalars are supported')
                require(not oneof.options.SerializeToString(), where, 'oneof options are not supported')
            fields = set()
            numbers = set()
            for field in message.field:
                where = loc + '.' + field.name
                require(re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)*', field.name)
                        and field.name not in KEYWORDS, where, 'field name is not a supported Roc identifier')
                require(field.name not in fields and field.number not in numbers, where, 'duplicate field')
                fields.add(field.name)
                numbers.add(field.number)
                require(1 <= field.number <= 536870911 and not 19000 <= field.number <= 19999,
                        where, 'invalid field number')
                require(field.type in SCALARS and field.label == d.FieldDescriptorProto.LABEL_OPTIONAL
                        and not field.HasField('default_value') and not field.type_name and not field.extendee,
                        where, 'only singular scalar fields are supported')
                if field.proto3_optional:
                    require(field.HasField('oneof_index') and 0 <= field.oneof_index < len(message.oneof_decl),
                            where, 'optional scalar requires a synthetic oneof')
                else:
                    require(not field.HasField('oneof_index'), where, 'real oneofs are not supported')
                require(not field.options.SerializeToString(), where, 'field options are not supported')
            messages.append(message)
    require(messages, 'request', 'no messages requested')
    return messages


def emit(message):
    name = message.name
    fields = sorted(message.field, key=lambda f: f.number)
    shape = ', '.join(f'{f.name} : ' + (f'[Absent, Present({SCALARS[f.type][0]})]' if f.proto3_optional else SCALARS[f.type][0]) for f in fields)
    defaults = ', '.join(f'{f.name}: ' + ('Absent' if f.proto3_optional else SCALARS[f.type][3]) for f in fields)
    imports = ['import wire.ProtobufWire']
    if any(f.type not in WIRE_TYPES for f in fields):
        imports.append('import wire.ProtobufScalar')
    lines = [
        '# Generated by protoc-gen-roc; regenerate from the schema.',
        *imports, '', f'{name} := {{ {shape} }}.{{',
        '\tis_eq : _', f'\tdefaults : {name}', f'\tdefaults = {name}.{{ {defaults} }}', '',
        f'\tdecode : List(U8), ProtobufWire.Limits -> Try({name}, ProtobufWire.Error)',
        '\tdecode = |input, limits| {',
        '\t\tvar $reader = ProtobufWire.new_reader(input, limits)?',
        f'\t\tvar $value = {{ {defaults} }}',
        '\t\twhile ProtobufWire.remaining($reader) > 0 {',
        '\t\t\t(field, after_tag) = ProtobufWire.read_tag($reader)?',
        '\t\t\t$reader = after_tag', '\t\t\tmatch (field.number, field.kind) {',
    ]
    for f in fields:
        _, kind, operation, _ = SCALARS[f.type]
        codec = 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        lines += [f'\t\t\t\t({f.number}, {kind}) => {{',
                  f'\t\t\t\t\t(value, after) = {codec}.read_{operation}($reader)?',
                  '\t\t\t\t\t$reader = after',
                  f'\t\t\t\t\t$value = {{ ..$value, {f.name}: {"Present(value)" if f.proto3_optional else "value"} }}', '\t\t\t\t}']
    lines += ['\t\t\t\t_ => { $reader = ProtobufWire.skip($reader, field)? }',
              '\t\t\t}', '\t\t}', f'\t\tOk({name}.($value))', '\t}', '',
              f'\tencode : {name}, U64 -> Try(List(U8), ProtobufWire.Error)',
              f'\tencode = |{name}.({"value" if fields else "_value"}), max_bytes| {{',
              '\t\tvar $writer = ProtobufWire.new_writer(max_bytes)']
    for f in fields:
        _, kind, operation, default = SCALARS[f.type]
        codec = 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        if f.proto3_optional:
            lines += [f'\t\tmatch value.{f.name} {{', '\t\t\tAbsent => {}',
                      '\t\t\tPresent(present_value) => {',
                      f'\t\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      f'\t\t\t\t$writer = {codec}.write_{operation}($writer, present_value)?',
                      '\t\t\t}', '\t\t}']
        else:
            # Only positive zero is the implicit default; retain IEEE negative zero.
            nondefault = (f'value.{f.name}.to_bits() != 0' if f.type in FLOAT_TYPES
                          else f'value.{f.name} != {default}')
            lines += [f'\t\tif {nondefault} {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      f'\t\t\t$writer = {codec}.write_{operation}($writer, value.{f.name})?', '\t\t}']
    lines += ['\t\tOk(ProtobufWire.output($writer))', '\t}', '}', '']
    return '\n'.join(lines)


def generate(request):
    response = p.CodeGeneratorResponse()
    try:
        messages = validate(request)
        response.supported_features = p.CodeGeneratorResponse.FEATURE_PROTO3_OPTIONAL
        for message in sorted(messages, key=lambda m: m.name):
            response.file.add(name=message.name + '.roc', content=emit(message))
        modules = ', '.join(sorted(m.name for m in messages))
        response.file.add(name='main.roc', content=f'package\n    [{modules}]\n    {{ wire: "{request.parameter[5:]}" }}\n')
    except ValueError as error:
        response.ClearField('file')
        response.error = str(error)
    return response


def main():
    try:
        request = p.CodeGeneratorRequest.FromString(sys.stdin.buffer.read())
        response = generate(request)
    except DecodeError:
        response = p.CodeGeneratorResponse(error='invalid CodeGeneratorRequest')
    sys.stdout.buffer.write(response.SerializeToString())


if __name__ == '__main__':
    main()
