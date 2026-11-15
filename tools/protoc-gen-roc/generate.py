"""Strict message codec pilot of the protoc plugin protocol. No roxum runtime dependency."""
import re
import sys
from google.protobuf import descriptor_pb2 as d
from google.protobuf.compiler import plugin_pb2 as p
from google.protobuf.message import DecodeError
import schema
import enums
import maps
import oneofs
import recursion

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
ENUM = d.FieldDescriptorProto.TYPE_ENUM
MESSAGE = d.FieldDescriptorProto.TYPE_MESSAGE
WIRE_TYPES = {d.FieldDescriptorProto.TYPE_UINT64, d.FieldDescriptorProto.TYPE_FIXED32,
              d.FieldDescriptorProto.TYPE_FIXED64, d.FieldDescriptorProto.TYPE_BYTES}
PACKABLE_TYPES = (set(SCALARS) | {ENUM}) - {d.FieldDescriptorProto.TYPE_STRING, d.FieldDescriptorProto.TYPE_BYTES}
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
        require(not file.extension, filename, 'extensions are not supported')
        require(not file.options.SerializeToString() and not file.HasField('edition'), filename, 'file options and editions are not supported')
    for symbol in messages:
        message = symbol.descriptor
        loc = symbol.location
        if symbol.is_enum:
            enums.validate(symbol, KEYWORDS)
            continue
        require(not message.extension and not message.extension_range,
                loc, 'extensions are not supported')
        options = d.MessageOptions()
        options.CopyFrom(message.options)
        if maps.is_entry(symbol):
            options.ClearField('map_entry')
        require(not options.SerializeToString(), loc, 'message options are not supported')
        oneofs.validate(symbol, KEYWORDS)
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
            require((field.type in SCALARS or field.type in (MESSAGE, ENUM)) and (field.label == d.FieldDescriptorProto.LABEL_OPTIONAL
                         or (repeated(field) and field.type in PACKABLE_TYPES | {d.FieldDescriptorProto.TYPE_STRING, d.FieldDescriptorProto.TYPE_BYTES, MESSAGE}))
                    and not field.HasField('default_value') and not field.extendee
                    and (field.type in (MESSAGE, ENUM) or not field.type_name),
                    where, 'only singular fields and repeated scalar/message fields are supported')
            require(not repeated(field) or not field.proto3_optional, where, 'repeated fields cannot be optional')
            options = d.FieldOptions()
            options.CopyFrom(field.options)
            if repeated(field) and field.type in PACKABLE_TYPES:
                options.ClearField('packed')
            require(not options.SerializeToString(), where, 'only packed on supported repeated numeric fields is accepted')
    identities = schema.references(files, messages)
    maps.validate(messages, identities)
    return messages, identities


def emit(symbol, identities, paths, components):
    message = symbol.descriptor
    name = symbol.roc_name
    fields = sorted(message.field, key=lambda f: f.number)
    def info(field):
        if field.type == MESSAGE:
            return (paths[field.type_name], 'Bytes', 'message', 'Absent')
        if field.type == ENUM:
            name = identities[field.type_name].roc_name
            return (name, 'Varint', 'int32', name + '.from_number(0)')
        return SCALARS[field.type]

    def boxed(field, owner=symbol):
        return recursion.boxed(owner, field, components)

    def wrap(field, value):
        return f'Box.box({value})' if boxed(field) else value

    def unwrap(field, value):
        return f'Box.unbox({value})' if boxed(field) else value

    def payload_type(field):
        return f'Box({info(field)[0]})' if boxed(field) else info(field)[0]

    def present(field):
        return field.proto3_optional or field.type == MESSAGE

    def map_entry(field):
        return identities[field.type_name] if field.type == MESSAGE and maps.is_entry(identities[field.type_name]) else None

    def entry_fields(entry):
        return sorted(entry.descriptor.field, key=lambda f: f.number)

    def field_type(field):
        entry = map_entry(field)
        if entry:
            key, value = entry_fields(entry)
            return f'Dict({info(key)[0]}, {info(value)[0]})'
        if repeated(field):
            return f'List({info(field)[0]})'
        return f'[Absent, Present({payload_type(field)})]' if present(field) else info(field)[0]

    ordinary = [f for f in fields if not oneofs.real(f)]
    groups = {index: [f for f in fields if oneofs.real(f) and f.oneof_index == index]
              for index in range(len(message.oneof_decl))}
    groups = {index: members for index, members in groups.items() if members}
    shape_parts = [f'{f.name} : ' + field_type(f) for f in ordinary]
    for index, members in groups.items():
        cases = ', '.join(f'{oneofs.tag(f)}({payload_type(f)})' for f in members)
        shape_parts.append(f'{message.oneof_decl[index].name} : [Unset, {cases}]')
    shape = ', '.join(shape_parts)
    defaults = ', '.join(f'{f.name}: ' + ('Dict.empty()' if map_entry(f) else '[]' if repeated(f) else 'Absent' if present(f) else info(f)[3]) for f in ordinary)
    defaults = ', '.join(filter(None, [defaults, ', '.join(message.oneof_decl[i].name + ': Unset' for i in groups)]))
    imports = ['import wire.ProtobufWire']
    if any(f.type in SCALARS and f.type not in WIRE_TYPES for f in fields):
        imports.append('import wire.ProtobufScalar')
    imports.extend('import ' + name for name in sorted({info(f)[0] for f in fields if f.type in (MESSAGE, ENUM)}))
    imports.extend('import ' + module for module in sorted({info(v)[0] for f in fields if map_entry(f) for v in entry_fields(map_entry(f)) if v.type in (MESSAGE, ENUM)}) if 'import ' + module not in imports)
    imports = sorted(set(line if line.startswith('import wire.') else 'import ' + line[7:].split('.')[0] for line in imports))
    imports = [line for line in imports if line != 'import ' + components.get(symbol.full_name, '')]
    lines = [
        '# Generated by protoc-gen-roc; regenerate from the schema.',
        f'# Protobuf message: {symbol.full_name}',
        *imports, '', f'{name} := {{ {shape} }}.{{',
        ('\tis_eq : _' if recursion.equality_supported(symbol, identities, components) else ''), f'\tdefaults : {name}', f'\tdefaults = {name}.{{ {defaults} }}', '',
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
        if oneofs.real(f):
            group = message.oneof_decl[f.oneof_index].name
            case = oneofs.tag(f)
            child, kind, operation, _ = info(f)
            lines += [f'\t\t\t\t({f.number}, {kind}) => {{']
            if f.type == MESSAGE:
                lines += [f'\t\t\t\t\tprevious = match $value.{group} {{\n\t\t\t\t\t\t{case}(value) => {unwrap(f, "value")}\n\t\t\t\t\t\t_ => {child}.defaults\n\t\t\t\t\t}}',
                          '\t\t\t\t\tinside = ProtobufWire.enter_message($reader)?',
                          f'\t\t\t\t\t(value, after) = {child}.decode_into(inside, previous)?',
                          '\t\t\t\t\t$reader = ProtobufWire.leave_message(after)?']
            else:
                codec = child if f.type == ENUM else 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
                lines += [f'\t\t\t\t\t(value, after) = {codec}.read_{operation}($reader)?',
                          '\t\t\t\t\t$reader = after']
            lines += [f'\t\t\t\t\t$value = {{ ..$value, {group}: {case}({wrap(f, "value")}) }}', '\t\t\t\t}']
            continue
        entry = map_entry(f)
        if entry:
            _, value_field = entry_fields(entry)
            extracted = 'item.value'
            if value_field.type == MESSAGE:
                extracted = (f'match item.value {{\n\t\t\t\t\t\tAbsent => {info(value_field)[0]}.defaults'
                             f'\n\t\t\t\t\t\tPresent(value) => {"Box.unbox(value)" if boxed(value_field, entry) else "value"}\n\t\t\t\t\t}}')
            lines += [f'\t\t\t\t({f.number}, Bytes) => {{',
                      '\t\t\t\t\treserved = ProtobufWire.reserve($reader, 1, 0)?',
                      '\t\t\t\t\tinside = ProtobufWire.enter_message(reserved)?',
                      f'\t\t\t\t\t({entry.roc_name}.(item), after) = {entry.roc_name}.decode_into(inside, {entry.roc_name}.defaults)?',
                      '\t\t\t\t\t$reader = ProtobufWire.leave_message(after)?',
                      f'\t\t\t\t\tmap_value = {extracted}',
                      f'\t\t\t\t\t$value = {{ ..$value, {f.name}: Dict.insert($value.{f.name}, item.key, map_value) }}',
                      '\t\t\t\t}']
            continue
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
                      f'\t\t\t\t\tprevious = match $value.{f.name} {{\n\t\t\t\t\t\tAbsent => {child}.defaults\n\t\t\t\t\t\tPresent(value) => {unwrap(f, "value")}\n\t\t\t\t\t}}',
                      '\t\t\t\t\tinside = ProtobufWire.enter_message($reader)?',
                      f'\t\t\t\t\t(value, after) = {child}.decode_into(inside, previous)?',
                      '\t\t\t\t\t$reader = ProtobufWire.leave_message(after)?',
                      f'\t\t\t\t\t$value = {{ ..$value, {f.name}: Present({wrap(f, "value")}) }}', '\t\t\t\t}']
            continue
        _, kind, operation, _ = info(f)
        codec = info(f)[0] if f.type == ENUM else 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        if repeated(f):
            lines += [f'\t\t\t\t({f.number}, {kind}) => {{',
                      '\t\t\t\t\treserved = ProtobufWire.reserve($reader, 1, 0)?',
                      f'\t\t\t\t\t(value, after) = {codec}.read_{operation}(reserved)?',
                      '\t\t\t\t\t$reader = after',
                      f'\t\t\t\t\t$value = {{ ..$value, {f.name}: $value.{f.name}.append(value) }}',
                      '\t\t\t\t}']
            if f.type in PACKABLE_TYPES:
                packed_reader = {'Varint': 'varints', 'Fixed32': 'fixed32', 'Fixed64': 'fixed64'}[kind]
                packed_codec = 'ProtobufWire'
                if f.type not in WIRE_TYPES and f.type != d.FieldDescriptorProto.TYPE_UINT32:
                    packed_codec, packed_reader = codec, operation
                converted = 'item.to_u32_wrap()' if f.type == d.FieldDescriptorProto.TYPE_UINT32 else 'item'
                lines += [f'\t\t\t\t({f.number}, Bytes) => {{',
                          f'\t\t\t\t\t(items, after) = {packed_codec}.read_packed_{packed_reader}($reader)?',
                          '\t\t\t\t\t$reader = after',
                          '\t\t\t\t\tfor item in items {',
                          f'\t\t\t\t\t\t$value = {{ ..$value, {f.name}: $value.{f.name}.append({converted}) }}',
                          '\t\t\t\t\t}', '\t\t\t\t}']
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
              '\t\tvar $writer = ProtobufWire.begin_message(writer)?']
    for f in fields:
        if oneofs.real(f):
            group = message.oneof_decl[f.oneof_index].name
            child, kind, operation, _ = info(f)
            codec = child if f.type == ENUM else 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
            lines += [f'\t\tmatch value.{group} {{',
                      f'\t\t\t{oneofs.tag(f)}(item) => {{',
                      f'\t\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      (f'\t\t\t\t$writer = ProtobufWire.write_message($writer, {unwrap(f, "item")}, {child}.encode_into)?' if f.type == MESSAGE else f'\t\t\t\t$writer = {codec}.write_{operation}($writer, item)?'),
                      '\t\t\t}', '\t\t\t_ => {}', '\t\t}']
            continue
        entry = map_entry(f)
        if entry:
            _, value_field = entry_fields(entry)
            item_value = ('Present(Box.box(item))' if boxed(value_field, entry) else 'Present(item)') if value_field.type == MESSAGE else 'item'
            lines += [f'\t\tfor (key, item) in value.{f.name} {{',
                      f'\t\t\tentry = {entry.roc_name}.{{ key, value: {item_value} }}',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: Bytes }})?',
                      f'\t\t\t$writer = ProtobufWire.write_message($writer, entry, {entry.roc_name}.encode_into)?',
                      '\t\t}']
            continue
        _, kind, operation, default = info(f)
        codec = info(f)[0] if f.type == ENUM else 'ProtobufWire' if f.type in WIRE_TYPES else 'ProtobufScalar'
        if repeated(f) and f.type in PACKABLE_TYPES and (not f.options.HasField('packed') or f.options.packed):
            lines += [f'\t\tif value.{f.name}.len() > 0 {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: Bytes }})?',
                      f'\t\t\tencode_items : List({info(f)[0]}), ProtobufWire.Writer -> Try(ProtobufWire.Writer, ProtobufWire.Error)',
                      '\t\t\tencode_items = |items, child| {',
                      '\t\t\t\tvar $child = child',
                      '\t\t\t\tfor item in items {',
                      f'\t\t\t\t\t$child = {codec}.write_{operation}($child, item)?',
                      '\t\t\t\t}', '\t\t\t\tOk($child)', '\t\t\t}',
                      f'\t\t\t$writer = ProtobufWire.write_message($writer, value.{f.name}, encode_items)?',
                      '\t\t}']
        elif repeated(f):
            lines += [f'\t\tfor item in value.{f.name} {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      (f'\t\t\t$writer = ProtobufWire.write_message($writer, item, {info(f)[0]}.encode_into)?' if f.type == MESSAGE else f'\t\t\t$writer = {codec}.write_{operation}($writer, item)?'), '\t\t}']
        elif present(f):
            lines += [f'\t\tmatch value.{f.name} {{', '\t\t\tAbsent => {}',
                      '\t\t\tPresent(present_value) => {',
                      f'\t\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      (f'\t\t\t\t$writer = ProtobufWire.write_message($writer, {unwrap(f, "present_value")}, {info(f)[0]}.encode_into)?' if f.type == MESSAGE else f'\t\t\t\t$writer = {codec}.write_{operation}($writer, present_value)?'),
                      '\t\t\t}', '\t\t}']
        else:
            # Only positive zero is the implicit default; retain IEEE negative zero.
            nondefault = (f'value.{f.name}.to_bits() != 0' if f.type in FLOAT_TYPES
                          else f'value.{f.name} != {default}')
            lines += [f'\t\tif {nondefault} {{',
                      f'\t\t\t$writer = ProtobufWire.write_tag($writer, {{ number: {f.number}, kind: {kind} }})?',
                      f'\t\t\t$writer = {codec}.write_{operation}($writer, value.{f.name})?', '\t\t}']
    lines += ['\t\tProtobufWire.end_message($writer)', '\t}', '}', '']
    return '\n'.join(lines)


def generate(request):
    response = p.CodeGeneratorResponse()
    try:
        messages, identities = validate(request)
        response.supported_features = p.CodeGeneratorResponse.FEATURE_PROTO3_OPTIONAL
        paths, components = recursion.layout(messages, identities)
        output = {}
        for message in messages:
            content = enums.emit(message) if message.is_enum else emit(message, identities, paths, components)
            output.setdefault(components.get(message.full_name, message.roc_name), []).append(content)
        for module, sources in sorted(output.items()):
            if module in components.values():
                imports, definitions = set(), []
                for source in sources:
                    lines = source.splitlines()
                    imports.update(line for line in lines if line.startswith('import '))
                    definitions.append('\n'.join('\t' + line for line in lines if not line.startswith('import ') and not line.startswith('# Generated')))
                content = ('# Generated by protoc-gen-roc; regenerate from the schema.\n'
                           + '\n'.join(sorted(imports)) + '\n\n' + module + ' := [].{\n'
                           + '\n'.join(definitions) + '\n}\n')
            else:
                content = sources[0]
            response.file.add(name=module + '.roc', content=content)
        modules = ', '.join(sorted(output))
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
