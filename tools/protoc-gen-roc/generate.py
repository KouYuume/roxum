"""Strict message codec pilot of the protoc plugin protocol. No roxum runtime dependency."""
import re
import sys
from google.protobuf import descriptor_pb2 as d
from google.protobuf.compiler import plugin_pb2 as p
from google.protobuf.message import DecodeError
import schema

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
MESSAGE = d.FieldDescriptorProto.TYPE_MESSAGE
WIRE_TYPES = {d.FieldDescriptorProto.TYPE_UINT64, d.FieldDescriptorProto.TYPE_FIXED32,
              d.FieldDescriptorProto.TYPE_FIXED64, d.FieldDescriptorProto.TYPE_BYTES}
FLOAT_TYPES = {d.FieldDescriptorProto.TYPE_FLOAT, d.FieldDescriptorProto.TYPE_DOUBLE}
KEYWORDS = set('app package platform provides exposes imports import as if then else match when is expect dbg crash return var for in while and or not where type alias implements with exposing generates has hosted interface module packages requires targets break'.split())
RESERVED = {'Builtin', 'ProtobufScalar', 'ProtobufWire', 'List', 'Try', 'U64', 'U32', 'U8', 'Bool', 'Str', 'Main', 'Box', 'Dec', 'F32', 'F64', 'I8', 'I16', 'I32', 'I64', 'I128', 'U16', 'U128', 'Set', 'Dict'}


def repeated(field):
    return field.label == d.FieldDescriptorProto.LABEL_REPEATED


def require(condition, location, reason):
    if not condition:
        raise ValueError(f'{location}: {reason}')


def validate(request):
    require(re.fullmatch(r'wire=[A-Za-z0-9_./:-]+', request.parameter), 'parameter',
            'expected wire=<Roc package path>; only letters, digits, _, ., /, :, - are accepted')
    files, messages = schema.index(request, RESERVED)
    for filename in sorted(request.file_to_generate):
        file = files[filename]
        require(file.syntax == 'proto3', filename, 'only proto3 is supported')
        require(not file.enum_type and not file.extension, filename, 'enums and extensions are not supported')
        require(not file.options.SerializeToString() and not file.HasField('edition'), filename, 'file options and editions are not supported')
    for symbol in messages:
        message = symbol.descriptor
        loc = symbol.location
        require(not message.enum_type and not message.extension and not message.extension_range,
                loc, 'enums and extensions are not supported')
        require(not message.options.SerializeToString(), loc, 'message options are not supported')
        oneof_names = set()
        for index, oneof in enumerate(message.oneof_decl):
            where = loc + '.' + oneof.name
            require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', oneof.name)
                    and oneof.name not in oneof_names, where, 'invalid or duplicate oneof name')
            oneof_names.add(oneof.name)
            members = [f for f in message.field if f.HasField('oneof_index') and f.oneof_index == index]
            require(len(members) == 1 and members[0].proto3_optional, where,
                    'only synthetic oneofs for proto3 optional fields are supported')
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
            require((field.type in SCALARS or field.type == MESSAGE) and (field.label == d.FieldDescriptorProto.LABEL_OPTIONAL
                         or (repeated(field) and field.type in {d.FieldDescriptorProto.TYPE_STRING, d.FieldDescriptorProto.TYPE_BYTES, MESSAGE}))
                    and not field.HasField('default_value') and not field.extendee
                    and (field.type == MESSAGE or not field.type_name),
                    where, 'only singular fields and repeated string/bytes/message fields are supported')
            require(not repeated(field) or not field.proto3_optional, where, 'repeated fields cannot be optional')
            if field.proto3_optional:
                require(field.HasField('oneof_index') and 0 <= field.oneof_index < len(message.oneof_decl),
                        where, 'optional field requires a synthetic oneof')
            else:
                require(not field.HasField('oneof_index'), where, 'real oneofs are not supported')
            require(not field.options.SerializeToString(), where, 'field options are not supported')
    return messages, schema.references(files, messages)


def emit(symbol, identities):
    message = symbol.descriptor
    name = symbol.roc_name
    fields = sorted(message.field, key=lambda f: f.number)
    def info(field):
        if field.type == MESSAGE:
            return (identities[field.type_name].roc_name, 'Bytes', 'message', 'Absent')
        return SCALARS[field.type]

    def present(field):
        return field.proto3_optional or field.type == MESSAGE

    def field_type(field):
        if repeated(field):
            return f'List({info(field)[0]})'
        return f'[Absent, Present({info(field)[0]})]' if present(field) else info(field)[0]

    shape = ', '.join(f'{f.name} : ' + field_type(f) for f in fields)
    defaults = ', '.join(f'{f.name}: ' + ('[]' if repeated(f) else 'Absent' if present(f) else info(f)[3]) for f in fields)
    imports = ['import wire.ProtobufWire']
    if any(f.type in SCALARS and f.type not in WIRE_TYPES for f in fields):
        imports.append('import wire.ProtobufScalar')
    imports.extend('import ' + name for name in sorted({info(f)[0] for f in fields if f.type == MESSAGE}))
    lines = [
        '# Generated by protoc-gen-roc; regenerate from the schema.',
        f'# Protobuf message: {symbol.full_name}',
        *imports, '', f'{name} := {{ {shape} }}.{{',
        '\tis_eq : _', f'\tdefaults : {name}', f'\tdefaults = {name}.{{ {defaults} }}', '',
        f'\tdecode : List(U8), ProtobufWire.Limits -> Try({name}, ProtobufWire.Error)',
        '\tdecode = |input, limits| {',
        '\t\treader = ProtobufWire.new_reader(input, limits)?',
        f'\t\t(value, _) = {name}.decode_into(reader, {name}.defaults)?',
        '\t\tOk(value)', '\t}', '',
        '\t## Consumes the current reader scope and merges wire occurrences into initial.',
        '\t## Thread the returned reader onward; this does not enter or leave a message.',
        f'\tdecode_into : ProtobufWire.Reader, {name} -> Try(({name}, ProtobufWire.Reader), ProtobufWire.Error)',
        f'\tdecode_into = |reader, {name}.(initial)| {{',
        '\t\tvar $reader = reader',
        '\t\tvar $value = initial',
        '\t\twhile ProtobufWire.remaining($reader) > 0 {',
        '\t\t\t(field, after_tag) = ProtobufWire.read_tag($reader)?',
        '\t\t\t$reader = after_tag', '\t\t\tmatch (field.number, field.kind) {',
    ]
    for f in fields:
        if f.type == MESSAGE:
            child = info(f)[0]
            if repeated(f):
                lines += [f'\t\t\t\t({f.number}, Bytes) => {{',
                          '\t\t\t\t\treserved = ProtobufWire.reserve($reader, 1, 0)?',
                          '\t\t\t\t\tinside = ProtobufWire.enter_message(reserved)?',
                          f'\t\t\t\t\t(value, after) = {child}.decode_into(inside, {child}.defaults)?',
                          '\t\t\t\t\t$reader = ProtobufWire.leave_message(after)?',
                          f'\t\t\t\t\t$value = {{ ..$value, {f.name}: $value.{f.name}.append(value) }}',
                          '\t\t\t\t}']
                continue
            lines += [f'\t\t\t\t({f.number}, Bytes) => {{',
                      f'\t\t\t\t\tprevious = match $value.{f.name} {{\n\t\t\t\t\t\tAbsent => {child}.defaults\n\t\t\t\t\t\tPresent(value) => value\n\t\t\t\t\t}}',
                      '\t\t\t\t\tinside = ProtobufWire.enter_message($reader)?',
                      f'\t\t\t\t\t(value, after) = {child}.decode_into(inside, previous)?',
                      '\t\t\t\t\t$reader = ProtobufWire.leave_message(after)?',
                      f'\t\t\t\t\t$value = {{ ..$value, {f.name}: Present(value) }}', '\t\t\t\t}']
            continue
        _, kind, operation, _ = info(f)
        codec = 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        if repeated(f):
            lines += [f'\t\t\t\t({f.number}, {kind}) => {{',
                      '\t\t\t\t\treserved = ProtobufWire.reserve($reader, 1, 0)?',
                      f'\t\t\t\t\t(value, after) = {codec}.read_{operation}(reserved)?',
                      '\t\t\t\t\t$reader = after',
                      f'\t\t\t\t\t$value = {{ ..$value, {f.name}: $value.{f.name}.append(value) }}',
                      '\t\t\t\t}']
            continue
        lines += [f'\t\t\t\t({f.number}, {kind}) => {{',
                  f'\t\t\t\t\t(value, after) = {codec}.read_{operation}($reader)?',
                  '\t\t\t\t\t$reader = after',
                  f'\t\t\t\t\t$value = {{ ..$value, {f.name}: {"Present(value)" if present(f) else "value"} }}', '\t\t\t\t}']
    lines += ['\t\t\t\t_ => { $reader = ProtobufWire.skip($reader, field)? }',
              '\t\t\t}', '\t\t}', f'\t\tOk(({name}.($value), $reader))', '\t}', '',
              f'\tencode : {name}, U64 -> Try(List(U8), ProtobufWire.Error)',
              '\tencode = |value, max_bytes| {',
              f'\t\twriter = {name}.encode_into(value, ProtobufWire.new_writer(max_bytes))?',
              '\t\tOk(ProtobufWire.output(writer))', '\t}', '',
              '\t## Appends fields to the supplied writer, retaining its accumulated output limit.',
              f'\tencode_into : {name}, ProtobufWire.Writer -> Try(ProtobufWire.Writer, ProtobufWire.Error)',
              f'\tencode_into = |{name}.({"value" if fields else "_value"}), writer| {{',
              '\t\tvar $writer = writer']
    for f in fields:
        _, kind, operation, default = info(f)
        codec = 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        if repeated(f):
            lines += [f'\t\tfor item in value.{f.name} {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      (f'\t\t\t$writer = ProtobufWire.write_message($writer, item, {info(f)[0]}.encode_into)?' if f.type == MESSAGE else f'\t\t\t$writer = {codec}.write_{operation}($writer, item)?'), '\t\t}']
        elif present(f):
            lines += [f'\t\tmatch value.{f.name} {{', '\t\t\tAbsent => {}',
                      '\t\t\tPresent(present_value) => {',
                      f'\t\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      (f'\t\t\t\t$writer = ProtobufWire.write_message($writer, present_value, {info(f)[0]}.encode_into)?' if f.type == MESSAGE else f'\t\t\t\t$writer = {codec}.write_{operation}($writer, present_value)?'),
                      '\t\t\t}', '\t\t}']
        else:
            # Only positive zero is the implicit default; retain IEEE negative zero.
            nondefault = (f'value.{f.name}.to_bits() != 0' if f.type in FLOAT_TYPES
                          else f'value.{f.name} != {default}')
            lines += [f'\t\tif {nondefault} {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      f'\t\t\t$writer = {codec}.write_{operation}($writer, value.{f.name})?', '\t\t}']
    lines += ['\t\tOk($writer)', '\t}', '}', '']
    return '\n'.join(lines)


def generate(request):
    response = p.CodeGeneratorResponse()
    try:
        messages, identities = validate(request)
        response.supported_features = p.CodeGeneratorResponse.FEATURE_PROTO3_OPTIONAL
        for message in messages:
            response.file.add(name=message.roc_name + '.roc', content=emit(message, identities))
        modules = ', '.join(sorted(m.roc_name for m in messages))
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
