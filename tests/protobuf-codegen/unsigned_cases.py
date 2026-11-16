"""Unsigned repeated fields: wire forms, merge order, and shared budgets."""
from scalar_cases import varint


# Independent schema contract: field number, name, fixed byte width, numeric width.
FIELDS = [(1, 'unsigned32', 0, 32), (2, 'unsigned64', 0, 64),
          (3, 'fixed32_value', 4, 32), (4, 'fixed64_value', 8, 64),
          (5, 'expanded32', 0, 32), (6, 'expanded64', 0, 64),
          (7, 'expanded_fixed32', 4, 32), (8, 'expanded_fixed64', 8, 64)]


def packed(number, payload):
    return varint(number * 8 + 2) + varint(len(payload)) + payload


def verify_unsigned(call, proto):
    def valid(data, path='/unsigned-lists'):
        kind = proto.UnsignedListEnvelope if path == '/unsigned-envelope' else proto.UnsignedLists
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        status, wire = call(path, data)
        assert status == 200, (path, data.hex(), status, wire)
        assert kind.FromString(wire) == expected, (data.hex(), wire.hex(), expected)
        if kind == proto.UnsignedLists:
            view = ';'.join(','.join(map(str, getattr(expected, name))) for _, name, _, _ in FIELDS).encode()
            assert call('/unsigned-view', data) == (200, view)
            # This fixture has one deterministic field order and output form.
            # Byte equality here verifies the explicit packed option, not a general
            # claim that protobuf serialization is canonical.
            assert wire == expected.SerializeToString(), (wire.hex(), expected)
        return wire

    valid(b'')
    status, wire = call('/unsigned-construct', b'')
    expected = proto.UnsignedLists(**{name: [0, (1 << bits)-1] for _, name, _, bits in FIELDS})
    assert status == 200 and proto.UnsignedLists.FromString(wire) == expected
    assert wire == expected.SerializeToString()
    for number, name, width, bits in FIELDS:
        encode = (lambda n: n.to_bytes(width, 'little')) if width else varint
        tag = varint(number * 8 + ({0: 0, 4: 5, 8: 1}[width]))
        # Lower/default, varint width transition, and unsigned upper boundary.
        values = [0, 1, 127, 128, (1 << bits)-2, (1 << bits)-1]
        valid(proto.UnsignedLists(**{name: values}).SerializeToString())
        payload = b''.join(map(encode, values))
        valid(packed(number, payload), '/unsigned-zero-depth')
        valid(b''.join(tag + encode(value) for value in values))
        mixed = packed(number, b'') + tag + encode(values[0])
        mixed += packed(number, b''.join(map(encode, values[1:3])))
        mixed += tag + encode(values[3]) + packed(number, b''.join(map(encode, values[4:])))
        valid(mixed + packed(number, b''))
        # Known fields with a third wire kind and unknown fields are skipped.
        wrong_kind = 1 if width != 8 else 5
        wrong = varint(number * 8 + wrong_kind) + b'\0' * (8 if wrong_kind == 1 else 4)
        valid(wrong + mixed + packed(9, b'ignored'))
        if width:
            for size in [width-1, width, width+1]:
                data = packed(number, b'\0'*size) + tag + encode(1)
                if size == width:
                    valid(data)
                else:
                    assert call('/unsigned-lists', data) == (400, b'Truncated')
        else:
            valid(packed(number, b'\x80\x00\xff\x00'))
            # uint32 keeps the low 32 bits in both wire forms.
            for n in [(1 << 32)-1, 1 << 32, (1 << 32)+1, (1 << 64)-1]:
                valid(packed(number, varint(n)) + tag + varint(n))
            for payload, error in [(b'\x80', b'Truncated'), (b'\xff'*9+b'\x02', b'VarintOverflow')]:
                assert call('/unsigned-lists', packed(number, payload)+tag+b'\x00') == (400, error)
        assert call('/unsigned-lists', varint(number*8+2)+b'\x02\x00') == (400, b'Truncated')

    # Multiple fields and both wire forms share one entry budget; no double charge.
    for count in [63, 64, 65]:
        data = packed(1, b'\x01'*31) + b'\x10\x02' + packed(5, b'\x03'*(count-32))
        if count <= 64:
            valid(data)
            valid(packed(1, data), '/unsigned-envelope')
        else:
            assert call('/unsigned-lists', data) == (400, b'EntryLimit')
            assert call('/unsigned-envelope', packed(1, data)) == (400, b'EntryLimit')
    for count in [127, 128, 129]:
        data = packed(1, b'') * count
        if count <= 128:
            valid(data)
        else:
            assert call('/unsigned-lists', data) == (400, b'TagLimit')
    for size in [255, 256, 257]:
        data = packed(4, b'\0'*size)
        if size == 256:
            valid(data)
        else:
            assert call('/unsigned-lists', data) == (400, b'Truncated' if size < 256 else b'FieldLimit')

    # Merged parents append segments in encounter order and retain their tail.
    first, last = packed(1, b'\x01\x02'), b'\x08\x03'
    valid(packed(1, first)+b'\x10\x2a'+packed(1, b'')+packed(1, last), '/unsigned-envelope')
    assert call('/unsigned-envelope', packed(1, b'\x0a\x02\x80')+b'\x10\x01') == (400, b'Truncated')
    status, wire = call('/unsigned-merge', first + last)
    original = proto.UnsignedLists(unsigned32=[42]).SerializeToString()
    assert status == 200 and wire.startswith(varint(len(original))+original)
    merged = proto.UnsignedLists.FromString(wire[len(original)+1:])
    assert list(merged.unsigned32) == [42, 1, 2, 3]

    # Packed output accounts for tags and length prefixes in the shared writer.
    for size in [15, 16, 17]:
        data = packed(1, b'\x01'*(size-4)) + b'\x28\x00'
        assert len(data) == size
        if size <= 16:
            valid(data, '/unsigned-output')
        else:
            assert call('/unsigned-output', data) == (400, b'OutputLimit')
    # Crossing a two-byte payload length prefix, with 64 entries at most.
    for size in [127, 128, 129]:
        payload = b'\x80\x80\x01'* (size//3) + b'\x01'*(size%3)
        valid(packed(1, payload))
    valid(b'')
