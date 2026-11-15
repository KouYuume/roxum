"""Validate synthetic map entry identities before treating repeated fields as Dicts."""
from google.protobuf import descriptor_pb2 as d
from schema import require

KEY_TYPES = {3, 4, 5, 6, 7, 8, 9, 13, 15, 16, 17, 18}


def is_entry(symbol):
    return not symbol.is_enum and symbol.descriptor.options.map_entry


def validate(messages, identities):
    uses = {m.full_name: [] for m in messages if is_entry(m)}
    for owner in messages:
        if owner.is_enum:
            continue
        for field in owner.descriptor.field:
            if field.type_name in uses:
                target = identities[field.type_name]
                require(field.type == d.FieldDescriptorProto.TYPE_MESSAGE
                        and field.label == d.FieldDescriptorProto.LABEL_REPEATED
                        and not field.proto3_optional and not field.HasField('oneof_index')
                        and target.full_name.rsplit('.', 1)[0] == owner.full_name,
                        owner.location + '.' + field.name, 'map entry must belong to its repeated parent field')
                uses[field.type_name].append(field)
    for entry in messages:
        if not is_entry(entry):
            continue
        msg = entry.descriptor
        require(len(uses[entry.full_name]) == 1, entry.location, 'map entry requires exactly one parent field')
        field = uses[entry.full_name][0]
        expected_name = ''.join(part.capitalize() for part in field.name.split('_')) + 'Entry'
        require(msg.name == expected_name, entry.location, 'map entry name does not match its parent field')
        require(not msg.nested_type and not msg.enum_type and not msg.oneof_decl
                and not msg.reserved_range and not msg.reserved_name,
                entry.location, 'map entry cannot contain nested declarations or reservations')
        fields = sorted(msg.field, key=lambda field: field.number)
        require(len(fields) == 2 and [(f.name, f.number) for f in fields] == [('key', 1), ('value', 2)],
                entry.location, 'map entry requires key=1 and value=2')
        require(all(f.label == d.FieldDescriptorProto.LABEL_OPTIONAL and not f.proto3_optional
                    and not f.HasField('oneof_index') for f in fields), entry.location,
                'map entry fields must be singular without explicit presence')
        require(fields[0].type in KEY_TYPES, entry.location, 'unsupported map key type')
        require(fields[1].type_name not in uses, entry.location, 'map values cannot be map entries')
