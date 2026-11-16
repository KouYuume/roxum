"""Signed, boolean, and IEEE list semantics against official Protobuf bindings."""
import math
import struct
from scalar_cases import bits, varint
from unsigned_cases import packed


# Field numbers and scalar kinds are the independent fixture schema contract.
BASE = [('signed32', 'int', 32), ('signed64', 'int', 64),
        ('zigzag32', 'zigzag', 32), ('zigzag64', 'zigzag', 64),
        ('signed_fixed32', 'fixed', 32), ('signed_fixed64', 'fixed', 64),
        ('enabled', 'bool', 64), ('float_value', 'float', 32), ('double_value', 'float', 64)]
FIELDS = [(i, name, kind, width) for i, (name, kind, width) in enumerate(BASE, 1)]
FIELDS += [(i+9, 'expanded_'+name, kind, width) for i, name, kind, width in FIELDS]


def normalized(value):
    result = []
    for _, name, kind, width in FIELDS:
        items = getattr(value, name)
        result.append([bits(n, width) for n in items] if kind == 'float'
                      else [int(n) for n in items])
    return result


def verify_scalar_lists(call, proto):
    message = proto.ScalarLists

    def valid(data, path='/scalar-lists'):
        expected = message.FromString(data)
        expected.DiscardUnknownFields()
        status, encoded = call(path, data)
        assert status == 200, (path, data.hex(), status, encoded)
        assert normalized(message.FromString(encoded)) == normalized(expected), (data.hex(), encoded.hex())
        view = ';'.join(','.join(map(str, items)) for items in normalized(expected)).encode()
        assert call('/scalar-lists-view', data) == (200, view)
        # Canonicalize NaN explicitly before comparing this fixture's output form.
        for _, name, kind, width in FIELDS:
            if kind == 'float':
                for i, value in enumerate(getattr(expected, name)):
                    if math.isnan(value):
                        getattr(expected, name)[i] = struct.unpack('<f' if width == 32 else '<d',
                            bits(value, width).to_bytes(width//8, 'little'))[0]
        assert encoded == expected.SerializeToString(), (data.hex(), encoded.hex())
        return encoded

    assert valid(b'') == b''
    for number, name, kind, width in FIELDS:
        fixed = kind in ('fixed', 'float')
        wire_kind = (5 if width == 32 else 1) if fixed else 0
        tag = varint(number*8 + wire_kind)
        if kind == 'float':
            fraction, exponent = (23, 8) if width == 32 else (52, 11)
            inf = ((1 << exponent)-1) << fraction
            patterns = [0, 1, 2, (1 << fraction)-1, 1 << fraction, (1 << fraction)+1,
                        inf-1, inf, inf+1, inf+(1 << (fraction-1)), inf+(1 << fraction)-1]
            # Every class, both signs, in both wire forms; compare NaNs by class.
            raw = [n | sign for n in patterns for sign in [0, 1 << (width-1)]]
            encode = lambda n: n.to_bytes(width//8, 'little')
        elif kind == 'bool':
            raw = [0, 1, 2, (1 << 32)-1, 1 << 32, (1 << 32)+1, (1 << 64)-1]
            encode = varint
        else:
            low, high = -(1 << (width-1)), (1 << (width-1))-1
            values = [low, low+1, -65, -64, -63, -1, 0, 1, 63, 64, 65, 127, 128, 129, high-1, high]
            valid(message(**{name: values}).SerializeToString())
            if kind == 'zigzag':
                raw = [((n << 1) ^ (n >> (width-1))) & ((1 << width)-1) for n in values]
            else:
                raw = [n & ((1 << (width if fixed else 64))-1) for n in values]
            encode = (lambda n: n.to_bytes(width//8, 'little')) if fixed else varint
        payloads = [encode(n) for n in raw]
        valid(packed(number, b''.join(payloads)))
        valid(b''.join(tag+p for p in payloads))
        mixed = packed(number, b'') + tag + payloads[0]
        mixed += packed(number, b''.join(payloads[1:-1])) + tag + payloads[-1] + packed(number, b'')
        valid(mixed)
        # Wrong wire kinds remain unknown; the valid list still follows them.
        wrong_kind = 0 if fixed else 5
        wrong = varint(number*8+wrong_kind) + (b'\0' if fixed else b'\0'*4)
        valid(wrong+mixed)
        if fixed:
            for size in [width//8-1, width//8, width//8+1]:
                data = packed(number, b'\0'*size) + tag + b'\0'*(width//8)
                if size == width//8:
                    valid(data)
                else:
                    assert call('/scalar-lists', data) == (400, b'Truncated')
        else:
            valid(packed(number, b'\x80\x00\x81\x00'))
            for raw_value in [(1 << 32)-1, 1 << 32, (1 << 32)+1, (1 << 64)-1]:
                valid(packed(number, varint(raw_value))+tag+varint(raw_value))
            for payload, error in [(b'\x80', b'Truncated'), (b'\xff'*9+b'\x02', b'VarintOverflow')]:
                assert call('/scalar-lists', packed(number, payload)+tag+b'\x00') == (400, error)
        assert call('/scalar-lists', varint(number*8+2)+b'\x02\x00') == (400, b'Truncated')

    # Values constructed in Roc prove encoders independently of decoding.
    status, wire = call('/scalar-lists-construct', b'')
    assert status == 200
    expected = message()
    for _, name, kind, width in FIELDS:
        values = ([0.0, -0.0, math.inf, math.nan] if kind == 'float' else
                  [False, True] if kind == 'bool' else
                  [-(1 << (width-1)), 0, (1 << (width-1))-1])
        getattr(expected, name).extend(values)
    assert normalized(message.FromString(wire)) == normalized(expected)

    # Shared entry accounting across typed packed lists, unpacked values and fields.
    for count in [63, 64, 65]:
        data = packed(3, b'\x01'*31) + b'\x38\x01' + packed(8, b'\0'*4*(count-32))
        if count <= 64:
            valid(data)
        else:
            assert call('/scalar-lists', data) == (400, b'EntryLimit')
    for count in [127, 128, 129]:
        data = packed(7, b'')*count
        if count <= 128:
            valid(data)
        else:
            assert call('/scalar-lists', data) == (400, b'TagLimit')
    for size in [255, 256, 257]:
        data = packed(9, b'\0'*size)
        if size == 256:
            valid(data)
        else:
            assert call('/scalar-lists', data) == (400, b'Truncated' if size < 256 else b'FieldLimit')

    # Parent merging appends, preserving zero-valued and NaN elements and a tail.
    first = message(signed32=[-1], float_value=[-0.0]).SerializeToString()
    last = message(signed32=[0], float_value=[math.nan]).SerializeToString()
    data = packed(1, first)+b'\x10\x2a'+packed(1, b'')+packed(1, last)
    status, wire = call('/scalar-lists-envelope', data)
    expected = proto.ScalarListEnvelope.FromString(data)
    assert status == 200
    actual = proto.ScalarListEnvelope.FromString(wire)
    assert actual.tail == expected.tail and normalized(actual.child) == normalized(expected.child)
    assert call('/scalar-lists-envelope', packed(1, b'\x42\x04\x00')+b'\x10\x01') == (400, b'Truncated')
    status, wire = call('/scalar-lists-merge', first+last)
    original = message(signed32=[-42], float_value=[-0.0]).SerializeToString()
    assert status == 200 and wire.startswith(varint(len(original))+original)
    merged = message.FromString(wire[len(original)+1:])
    wanted = message.FromString(original+first+last)
    assert normalized(merged) == normalized(wanted)

    for size in [15, 16, 17]:
        data = packed(3, b'\x01'*(size-2))
        assert len(data) == size
        if size <= 16:
            valid(data, '/scalar-lists-output')
        else:
            assert call('/scalar-lists-output', data) == (400, b'OutputLimit')
    valid(b'')
