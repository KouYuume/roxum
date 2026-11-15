"""Separate real oneof groups from proto3 optional presence metadata."""
import re
from google.protobuf import descriptor_pb2 as d
from schema import require


def real(field):
    return field.HasField('oneof_index') and not field.proto3_optional


def tag(field):
    return ''.join(part.capitalize() for part in field.name.split('_'))


def validate(symbol, keywords):
    message = symbol.descriptor
    names = set()
    synthetic_seen = False
    for index, group in enumerate(message.oneof_decl):
        location = symbol.location + '.' + group.name
        require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', group.name)
                and group.name not in names, location, 'invalid or duplicate oneof name')
        names.add(group.name)
        members = [f for f in message.field if f.HasField('oneof_index') and f.oneof_index == index]
        require(members, location, 'oneof must contain a field')
        require(not group.options.SerializeToString(), location, 'oneof options are not supported')
        if any(f.proto3_optional for f in members):
            require(len(members) == 1, location, 'synthetic oneof must contain exactly one optional field')
            synthetic_seen = True
        else:
            require(not synthetic_seen, location, 'real oneofs must precede synthetic oneofs')
            require(re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)*', group.name)
                    and group.name not in keywords, location, 'oneof name is not a supported Roc identifier')
            require(group.name not in {f.name for f in message.field}, location, 'oneof name collides with a field')
            tags = [tag(f) for f in members]
            require(len(set(tags)) == len(tags) and 'Unset' not in tags,
                    location, 'oneof case names collide with each other or Unset')
    for field in message.field:
        location = symbol.location + '.' + field.name
        if field.HasField('oneof_index'):
            require(0 <= field.oneof_index < len(message.oneof_decl), location, 'invalid oneof index')
            require(field.label == d.FieldDescriptorProto.LABEL_OPTIONAL,
                    location, 'oneof members must be singular')
        elif field.proto3_optional:
            require(False, location, 'optional field requires a synthetic oneof')
