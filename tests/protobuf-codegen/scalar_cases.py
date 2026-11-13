"""Scalar semantic comparisons with official Python Protobuf, including IEEE classes."""
import math
import random
import struct


def varint(number):
    data = bytearray()
    while number > 127:
        data.append((number & 127) | 128)
        number >>= 7
    data.append(number)
    return bytes(data)


def text_field(data):
    return b'\x4a' + varint(len(data)) + data


def bits(value, width):
    # Roc canonicalizes NaN on to_bits; compare the class, not its payload/sign.
    if math.isnan(value):
        return {32: 0x7fc00000, 64: 0x7ff8000000000000}[width]
    return int.from_bytes(struct.pack('<f' if width == 32 else '<d', value), 'little')


def verify_scalars(call, reference):
    message = reference.Scalars
    integer_fields = ['unsigned32', 'signed32', 'signed64', 'zigzag32', 'zigzag64',
                      'signed_fixed32', 'signed_fixed64']

    def valid(data):
        expected = message.FromString(data)
        status, encoded = call('/scalars', data)
        assert status == 200, (data.hex(), status, encoded)
        actual = message.FromString(encoded)
        for name in integer_fields + ['enabled', 'text']:
            assert getattr(actual, name) == getattr(expected, name), (name, expected, actual)
        for name, width in [('float_value', 32), ('double_value', 64)]:
            assert bits(getattr(actual, name), width) == bits(getattr(expected, name), width), (name, data.hex(), expected, actual)
        # Direct decoded values prevent inverse mistakes in the codec from cancelling.
        values = [getattr(expected, name) for name in integer_fields] + [int(expected.enabled),
                  bits(expected.float_value, 32), bits(expected.double_value, 64)]
        assert call('/scalar-view', data) == (200, ','.join(map(str, values)).encode())
        assert call('/scalar-text', data) == (200, expected.text.encode())
        return encoded

    assert valid(b'') == b''
    assert valid(b'\x4a\0\x55' + b'\0' * 4 + b'\x59' + b'\0' * 8) == b''
    for name in integer_fields:
        width = 32 if name.endswith('32') else 64
        signed = name != 'unsigned32'
        low, high = (-(1 << (width - 1)), (1 << (width - 1)) - 1) if signed else (0, (1 << width) - 1)
        values = {low, low + 1, high - 1, high, 0, 1}
        if signed:
            values.update([-1, -2])
        # Varint/ZigZag width transitions within each type's domain.
        for shift in range(6, width):
            if shift % 7 in (0, 6):
                for value in [(1 << shift) - 1, 1 << shift, (1 << shift) + 1]:
                    if value <= high:
                        values.add(value)
                    if signed and -value >= low:
                        values.add(-value)
        for value in sorted(values):
            valid(message(**{name: value}).SerializeToString())
    # Values beyond the declared 32-bit width truncate, after bounded 64-bit parsing.
    for field in [1, 2, 4]:
        for raw in [(1 << 32) - 1, 1 << 32, (1 << 32) + 1, (1 << 63), (1 << 64) - 1]:
            valid(bytes([field * 8]) + varint(raw))
    # Any nonzero varint decodes as true, including bits above 32-bit width.
    for raw in [0, 1, 2, (1 << 32), (1 << 64) - 1]:
        valid(b'\x40' + varint(raw))
    for value in ['', '\0', 'ASCII', 'あ🐦', '\ufeff', '\u007f', '\u0080', '\u07ff', '\u0800', '\ud7ff', '\ue000', '\uffff', '\U00010000', '\U0010ffff']:
        valid(message(text=value).SerializeToString())

    # Exact IEEE patterns exercise subnormal/normal boundaries, signed zeros,
    # both infinities, and quiet/signaling NaNs with distinct signs/payloads.
    for width, tag, fraction, exponent in [(32, b'\x55', 23, 8), (64, b'\x59', 52, 11)]:
        inf = ((1 << exponent) - 1) << fraction
        patterns = [0, 1, 2, (1 << fraction) - 1, 1 << fraction, (1 << fraction) + 1,
                    inf - 1, inf, inf + 1, inf + (1 << (fraction - 1)), inf + (1 << fraction) - 1]
        for pattern in patterns:
            for sign in [0, 1 << (width - 1)]:
                valid(tag + (pattern | sign).to_bytes(width // 8, 'little'))
    # Reordered and duplicate fields: the last occurrence wins even for defaults.
    first = message(unsigned32=7, signed32=-7, signed64=-8, zigzag32=-9, zigzag64=-10,
                    signed_fixed32=-11, signed_fixed64=-12, enabled=True, text='old', float_value=-0.0, double_value=math.inf)
    assert valid(first.SerializeToString() + b'\x08\0\x10\0\x18\0\x20\0\x28\0\x35' + b'\0'*4
          + b'\x39' + b'\0'*8 + b'\x40\0\x4a\0\x55' + b'\0'*4 + b'\x59' + b'\0'*8) == b''
    valid(b'\x55' + struct.pack('<f', -0.0) + b'\x55' + struct.pack('<f', 1.5))
    rng = random.Random(741)
    for _ in range(40):
        valid(message(unsigned32=rng.getrandbits(32), signed32=rng.randrange(-(1 << 31), 1 << 31),
                      signed64=rng.randrange(-(1 << 63), 1 << 63), zigzag32=rng.randrange(-(1 << 31), 1 << 31),
                      zigzag64=rng.randrange(-(1 << 63), 1 << 63), text=chr(rng.randrange(0x80)),
                      float_value=rng.uniform(-1000, 1000), double_value=rng.uniform(-1e100, 1e100)).SerializeToString())
    status, encoded = call('/scalar-construct', b'')
    assert status == 200
    actual = message.FromString(encoded)
    for name in integer_fields:
        width = 32 if name.endswith('32') else 64
        assert getattr(actual, name) == ((1 << 32) - 1 if name == 'unsigned32' else -(1 << (width - 1)))
    assert actual.enabled and actual.text == 'Roc 🐦'
    assert bits(actual.float_value, 32) == 0x80000000 and actual.double_value == math.inf

    def rejected(data, error, path='/scalars'):
        assert call(path, data) == (400, error.encode()), (data.hex(), error)

    # UTF-8 equivalence classes: stray continuation, overlong, surrogate,
    # above U+10FFFF, invalid lead byte, and truncated 2/3/4-byte sequences.
    for invalid in [b'\x80', b'\xc0\x80', b'\xc1\xbf', b'\xe0\x9f\xbf', b'\xed\xa0\x80',
                    b'\xed\xbf\xbf', b'\xf0\x8f\xbf\xbf', b'\xf4\x90\x80\x80', b'\xf5\x80\x80\x80',
                    b'\xff', b'\xc2', b'\xe1\x80', b'\xf1\x80\x80']:
        rejected(text_field(invalid), 'InvalidUtf8')
    # Unknown byte strings are not subject to known string UTF-8 validation.
    valid(b'\x62\x01\xff')
    # A known field with a wrong wire type is skipped as unknown.
    valid(b'\x48\x01\x52\x01\xff\x58\x01')
    for size in [255, 256]:
        valid(text_field(b'x' * size))
    rejected(text_field(b'x' * 257), 'FieldLimit')
    # Cumulative UTF-8 conversion costs twice its byte length, including duplicates.
    for cost in [510, 512, 514]:
        data = text_field(b'x' * 128) + text_field(b'y' * (cost // 2 - 128))
        if cost <= 512:
            valid(data)
        else:
            rejected(data, 'MaterializationLimit')
    for size in [15, 16, 17]:
        data = text_field(b'x' * (size - 2))
        if size <= 16:
            assert call('/scalar-limits', data) == (200, data)
        else:
            rejected(data, 'OutputLimit', '/scalar-limits')
    for data in [message(text='あ').SerializeToString(), message(float_value=1.5).SerializeToString(),
                 message(double_value=1.5).SerializeToString(), message(signed32=-1).SerializeToString()]:
        for length in range(1, len(data)):
            rejected(data[:length], 'Truncated')
    valid(message(signed32=-42, text='healthy').SerializeToString())
