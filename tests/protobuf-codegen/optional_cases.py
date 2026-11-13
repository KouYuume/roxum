"""Explicit presence compared with official Python bindings and direct Roc views."""
import math

from scalar_cases import bits, varint


def verify_optional(call, reference):
    message = reference.OptionalScalars
    fields = ['unsigned32', 'signed32', 'signed64', 'zigzag32', 'zigzag64',
              'signed_fixed32', 'signed_fixed64', 'enabled', 'text', 'float_value',
              'double_value', 'unsigned64', 'fixed32_value', 'fixed64_value', 'payload']
    defaults = [0] * 7 + [False, '', 0.0, 0.0, 0, 0, 0, b'']
    nondefaults = [(1 << 32) - 1, -(1 << 31), -(1 << 63), -(1 << 31), -(1 << 63),
                   -(1 << 31), -(1 << 63), True, 'あ🐦', -0.0, math.inf,
                   (1 << 64) - 1, (1 << 32) - 1, (1 << 64) - 1, b'\x00\xff']

    def compare(actual, expected):
        for name in fields:
            assert actual.HasField(name) == expected.HasField(name), (name, actual, expected)
            a, e = getattr(actual, name), getattr(expected, name)
            if name in ('float_value', 'double_value'):
                width = 32 if name == 'float_value' else 64
                assert bits(a, width) == bits(e, width), (name, actual, expected)
            else:
                assert a == e, (name, actual, expected)
        assert actual.implicit_value == expected.implicit_value

    def valid(data):
        expected = message.FromString(data)
        status, encoded = call('/optional', data)
        assert status == 200, (data.hex(), status, encoded)
        compare(message.FromString(encoded), expected)
        # Inspect values and presence separately from the generated encoder.
        view = []
        for name in fields:
            value = getattr(expected, name)
            if not expected.HasField(name):
                view.append('-')
            elif name in ('float_value', 'double_value'):
                view.append(str(bits(value, 32 if name == 'float_value' else 64)))
            elif name == 'text':
                view.append(str(len(value.encode())))
            elif name == 'payload':
                view.append(str(len(value)))
            else:
                view.append(str(int(value)))
        view.append(str(expected.implicit_value))
        assert call('/optional-view', data) == (200, ','.join(view).encode()), data.hex()
        for name, path in [('text', '/optional-text'), ('payload', '/optional-bytes')]:
            value = getattr(expected, name)
            if isinstance(value, str):
                value = value.encode()
            assert call(path, data) == (200, bytes([expected.HasField(name)]) + value), data.hex()
        return encoded

    assert valid(b'') == b''
    assert call('/optional-defaults', b'') == (200, b'')
    for name, default, other in zip(fields, defaults, nondefaults):
        present_default = message(**{name: default}).SerializeToString()
        present_other = message(**{name: other}).SerializeToString()
        assert present_default, name
        assert valid(present_default) == present_default
        valid(present_other)
        # Last occurrence wins in both directions, even when it is empty/zero.
        assert valid(present_other + present_default) == present_default
        assert valid(present_default + present_other) == present_other
        assert valid(present_default * 2) == present_default
        # A mismatched wire type must not set or clear this field's presence.
        field = message.DESCRIPTOR.fields_by_name[name]
        wrong = varint(field.number * 8 + (0 if name in ('text', 'payload') else 2)) + b'\0'
        assert valid(wrong) == b''
        assert valid(wrong + present_default + wrong) == present_default
        for end in range(1, len(present_other)):
            assert call('/optional', present_other[:end]) == (400, b'Truncated')

    all_defaults = message(**dict(zip(fields, defaults)))
    all_values = message(**dict(zip(fields, nondefaults)))
    valid(all_defaults.SerializeToString())
    valid(all_values.SerializeToString())
    valid(all_values.SerializeToString() + all_defaults.SerializeToString())
    status, constructed = call('/optional-construct', b'')
    assert status == 200
    compare(message.FromString(constructed), all_defaults)
    # Applications clear a presence tag without changing other fields.
    status, cleared = call('/optional-clear', all_values.SerializeToString())
    assert status == 200
    expected = message.FromString(all_values.SerializeToString())
    expected.ClearField('unsigned32')
    expected.ClearField('text')
    compare(message.FromString(cleared), expected)
    # Explicit and implicit fields coexist: only the implicit default is omitted.
    mixed = message(unsigned32=0, implicit_value=0).SerializeToString() + b'\x80\x01\0'
    assert valid(mixed) == b'\x08\0'
    valid(message(unsigned32=0, implicit_value=7).SerializeToString())
    valid(b'\x08\x80\0')  # non-minimal value varint still means present zero
    # Python dispatches on raw tag bytes; assert this Roc-only contract directly.
    assert call('/optional', b'\x88\0\0') == (200, b'\x08\0')
    assert call('/optional', b'\xf8\x01\0') == (200, b'')  # unknown field
    for name, tag, width in [('float_value', b'\x55', 32), ('double_value', b'\x59', 64)]:
        for value in [0.0, -0.0, 1.5, math.inf, -math.inf, math.nan]:
            valid(message(**{name: value}).SerializeToString())
        pattern = 0xff800001 if width == 32 else 0xfff0000000000001
        valid(tag + pattern.to_bytes(width // 8, 'little'))
    assert call('/optional', b'\x4a\x01\xff') == (400, b'InvalidUtf8')
    assert call('/optional', b'\x08' + b'\xff' * 9 + b'\x02') == (400, b'VarintOverflow')
    # Replaced present values still consume the shared cumulative budget.
    for total in [511, 512, 513]:
        data = (message(payload=b'x' * 256).SerializeToString()
                + message(payload=b'y' * 255).SerializeToString()
                + message(payload=b'z' * (total - 511)).SerializeToString())
        if total <= 512:
            valid(data)
        else:
            assert call('/optional', data) == (400, b'MaterializationLimit')
    for size in [255, 256, 257]:
        data = message(text='a' * size).SerializeToString()
        if size <= 256:
            valid(data)
        else:
            assert call('/optional', data) == (400, b'FieldLimit')
    for total in [510, 512, 514]:
        data = (message(text='x' * 255).SerializeToString()
                + message(text='y' * ((total - 510) // 2)).SerializeToString())
        if total <= 512:
            valid(data)
        else:
            assert call('/optional', data) == (400, b'MaterializationLimit')
    for tags in [127, 128, 129]:
        data = b'\x08\0' * tags
        if tags <= 128:
            assert valid(data) == b'\x08\0'
        else:
            assert call('/optional', data) == (400, b'TagLimit')
    for size in [15, 16, 17]:
        data = message(payload=b'x' * (size - 2)).SerializeToString()
        assert len(data) == size
        assert call('/optional-limits', data) == ((200, data) if size <= 16 else (400, b'OutputLimit'))
    valid(all_defaults.SerializeToString())  # failure paths leave subsequent requests usable
