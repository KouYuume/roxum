"""Generated codecs share reader scopes, merge state, and writer capacity."""
import math
from scalar_cases import bits, varint


def child(data):
    return b'\x0a' + varint(len(data)) + data


def compare(actual, expected):
    for field in expected.DESCRIPTOR.fields:
        name = field.name
        if field.has_presence:
            assert actual.HasField(name) == expected.HasField(name), name
        left, right = getattr(actual, name), getattr(expected, name)
        if name in ('float_value', 'double_value'):
            width = 32 if name == 'float_value' else 64
            assert bits(left, width) == bits(right, width), (name, left, right)
        else:
            assert left == right, (name, left, right)


def verify_composition(call, reference, envelope):
    def valid(data, scalar=False, path=None):
        outer = (envelope.ScalarEnvelope if scalar else envelope.OptionalEnvelope).FromString(data)
        message_type = reference.Scalars if scalar else reference.OptionalScalars
        status, encoded = call(path or ('/compose-scalars' if scalar else '/compose'), data)
        assert status == 200, (data.hex(), status, encoded)
        # Prefix, generated fields, and suffix must use one writer without resets.
        assert encoded[:4] == b'\x11\x22\x33\x44'
        assert encoded[-4:] == outer.tail.to_bytes(4, 'little')
        compare(message_type.FromString(encoded[4:-4]), outer.child)
        if not scalar:
            value = outer.child
            unsigned = str(value.unsigned32) if value.HasField('unsigned32') else '-'
            text = value.text if value.HasField('text') else '-'
            payload = str(len(value.payload)) if value.HasField('payload') else '-'
            view = f'{outer.tail},{unsigned},{text},{payload},{value.implicit_value}'.encode()
            assert call('/compose-view', data) == (200, view)
        return encoded

    def rejected(data, error, path='/compose'):
        assert call(path, data) == (400, error.encode()), (data.hex(), error)

    optional = reference.OptionalScalars
    nondefaults = dict(unsigned32=(1 << 32) - 1, signed32=-(1 << 31), signed64=-(1 << 63),
                       zigzag32=-1, zigzag64=-2, signed_fixed32=-3, signed_fixed64=-4,
                       enabled=True, text='a long retained string with 🐦', float_value=-0.0,
                       double_value=math.inf, unsigned64=(1 << 64) - 1,
                       fixed32_value=7, fixed64_value=8, payload=b'\x00\x80\xff' * 12)
    for name, value in nondefaults.items():
        field = optional.DESCRIPTOR.fields_by_name[name]
        first = optional(**{name: value}).SerializeToString()
        default = optional(**{name: field.default_value}).SerializeToString()
        # An empty occurrence retains previous values; present defaults overwrite.
        for later in [b'', default, first]:
            data = child(first) + child(later) + b'\x10\x2a'
            valid(data)
            status, retained = call('/compose-retained', data)
            assert status == 200
            compare(optional.FromString(retained[4:-4]), optional.FromString(first))
        # A different field's occurrence must merge without erasing this field.
        other = optional(implicit_value=9).SerializeToString()
        valid(child(first) + child(other) + b'\x10\x2a')
    all_values = optional(**nondefaults).SerializeToString()
    valid(child(all_values) + child(b'\x08\0') + b'\x10\x2a')
    valid(b'')
    valid(child(b''))
    valid(child(b'') + child(b'') + b'\x10\x2a')
    # Explicit zero on the wire replaces a prior implicit scalar even across scopes.
    valid(child(b'\x80\x01\x09') + child(b'\x80\x01\0') + b'\x10\x2a')
    # Wrong-wire and unknown fields do not replace existing state.
    valid(child(b'\x08\x07') + child(b'\x0a\0\x98\x01\x01') + b'\x10\x2a')
    values = {name: value for name, value in nondefaults.items() if name in reference.Scalars.DESCRIPTOR.fields_by_name}
    first = reference.Scalars(**values).SerializeToString()
    # These raw default occurrences cannot be obtained by serializing implicit defaults.
    defaults = b'\x08\0\x10\0\x18\0\x20\0\x28\0\x35' + b'\0'*4
    defaults += b'\x39' + b'\0'*8 + b'\x40\0\x4a\0\x55' + b'\0'*4 + b'\x59' + b'\0'*8
    for later in [b'', defaults, b'\x08\x07']:
        valid(child(first) + child(later) + b'\x10\x2a', scalar=True)

    # A child must not borrow bytes from the parent's tail to complete a value.
    for broken in [b'\x08', b'\x7d\x01\x02\x03', b'\x4a\x02x', b'\x4a', b'\x08\x80']:
        rejected(child(broken) + b'\x10\x01', 'Truncated')
    rejected(child(b'\x4a\x01\xff') + b'\x10\x01', 'InvalidUtf8')
    rejected(child(b'\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02'), 'VarintOverflow')
    rejected(child(b'\x0c'), 'UnexpectedEndGroup')
    rejected(child(b'') + b'\x10', 'Truncated')
    # Depth combines one entered message with unknown groups in its scope.
    for groups in [0, 1, 2]:
        data = child(b'\x9b\x01' * groups + b'\x9c\x01' * groups) + b'\x10\x2a'
        if groups <= 1:
            valid(data)
        else:
            rejected(data, 'DepthLimit')
    # Two parent tags plus child tags share one counter (limit 128).
    for count in [125, 126, 127]:
        data = child(b'\x08\x01' * count) + b'\x10\x2a'
        if count <= 126:
            valid(data)
        else:
            rejected(data, 'TagLimit')
    # Empty child scopes still charge parent tags; successful returns never replenish.
    valid(child(b'') * 127 + b'\x10\x2a')
    rejected(child(b'') * 128 + b'\x10\x2a', 'TagLimit')
    # Materialization survives sibling scopes and overwrites. Strings charge twice.
    for total in [511, 512, 513]:
        data = child(optional(text='x'*125).SerializeToString()) * 2
        data += child(optional(payload=b'y'*(total-500)).SerializeToString()) + b'\x10\x2a'
        if total <= 512:
            valid(data)
        else:
            rejected(data, 'MaterializationLimit')
    # Both the outer child and its inner unknown length field use field_bytes.
    for size in [255, 256, 257]:
        payload = b'\x8a\x01' + varint(size-4) + b'x'*(size-4)
        assert len(payload) == size
        data = child(payload) + b'\x10\x2a'
        if size <= 256:
            valid(data)
        else:
            rejected(data, 'FieldLimit')
    for total in [4095, 4096, 4097]:
        prefix = (b'\x1a' + varint(250) + b'x'*250) * 16 + child(b'') + b'\x10\x2a'
        data = prefix + b'\x1a' + varint(total-len(prefix)-2) + b'x'*(total-len(prefix)-2)
        assert len(data) == total
        if total <= 4096:
            valid(data)
        else:
            rejected(data, 'InputLimit')
    # The 16-byte writer includes a four-byte prefix and four-byte suffix.
    for total in [15, 16, 17]:
        data = child(optional(payload=b'x'*(total-10)).SerializeToString()) + b'\x10\x2a'
        if total <= 16:
            assert len(valid(data, path='/compose-output')) == total
        else:
            rejected(data, 'OutputLimit', '/compose-output')
    # Length-prefix width transitions and the complete 256-byte parent boundary.
    for size in [0, 1, 122, 123, 124, 125, 126, 127, 128, 246, 247, 248, 249]:
        data = child(optional(payload=b'x'*size).SerializeToString()) + b'\x10\x2a'
        expected = envelope.OptionalEnvelope.FromString(data)
        wire = expected.SerializeToString()
        status, encoded = call('/compose-message', data)
        if len(wire) <= 256:
            assert status == 200, (size, status, encoded)
            assert envelope.OptionalEnvelope.FromString(encoded) == expected
        else:
            assert (status, encoded) == (400, b'OutputLimit')

    # Output can also exhaust inside the generated fields, before the suffix.
    rejected(child(optional(payload=b'x'*11).SerializeToString()), 'OutputLimit', '/compose-output')
    valid(child(optional(unsigned32=42).SerializeToString()) + b'\x10\x2a')
