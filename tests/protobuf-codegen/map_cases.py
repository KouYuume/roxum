"""Maps compared by values, independently of dictionary serialization order."""
import math
import struct
from scalar_cases import varint
from unsigned_cases import packed


def verify_maps(call, proto):
    def valid(data, path='/maps'):
        kind = proto.MapEnvelope if path == '/maps-envelope' else proto.MapPacket
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        status, wire = call(path, data)
        assert status == 200, (path, data.hex(), status, wire)
        actual = kind.FromString(wire)
        assert actual == expected, (data.hex(), actual, expected)
        return wire

    valid(b'')
    # All legal map key encodings and scalar/enum/message value families.
    for name in ['signed32', 'signed64', 'unsigned32', 'unsigned64', 'flags', 'strings',
                 'zigzag32', 'zigzag64', 'fixed32', 'fixed64', 'sfixed32', 'sfixed64']:
        field = proto.MapPacket.DESCRIPTOR.fields_by_name[name]
        key = field.message_type.fields_by_name['key']
        if key.type == key.TYPE_STRING:
            keys = ['', 'a', 'heap-backed key 🐦' * 2]
        elif key.type == key.TYPE_BOOL:
            keys = [False, True]
        else:
            width = 32 if name.endswith('32') else 64
            unsigned = name.startswith(('unsigned', 'fixed'))
            low, high = (0, (1 << width) - 1) if unsigned else (-(1 << (width-1)), (1 << (width-1))-1)
            keys = [low, low+1, 0, 1, high-1, high]
        packet = proto.MapPacket()
        for index, item in enumerate(keys):
            mapping = getattr(packet, name)
            if name in ['flags', 'strings']:
                mapping[item].count = index
                mapping[item].payload = b'heap-backed payload ' * 2
            else:
                value = {'signed32': 'value 🐦', 'signed64': -7, 'unsigned32': b'\0\xff',
                         'unsigned64': 'value', 'zigzag32': -2, 'zigzag64': -3,
                         'fixed32': -1.5, 'fixed64': 2.5, 'sfixed32': True,
                         'sfixed64': (1 << 64)-1}[name]
                mapping[item] = value
        valid(packet.SerializeToString())
        # Missing both key and value inserts a default entry.
        valid(packed(field.number, b''))
    # Floating map values retain negative zero and infinities; NaNs are checked
    # by class, since the Roc scalar codec intentionally canonicalizes them.
    for field, fmt in [('fixed32','<f'), ('fixed64','<d')]:
        for number in [-0.0, float('inf'), -float('inf'), float('nan')]:
            packet = proto.MapPacket()
            getattr(packet,field)[1] = number
            status, wire = call('/maps',packet.SerializeToString())
            assert status == 200, wire
            value = getattr(proto.MapPacket.FromString(wire),field)[1]
            assert math.isnan(value) if math.isnan(number) else struct.pack(fmt,value) == struct.pack(fmt,number)
    # Missing key/value, duplicate key/value members, nonminimal varints, and
    # duplicate map entries, including overwriting a value with its default.
    for entry in [b'\x08\x01', packed(2,b'x'), b'\x08\x01\x08\0'+packed(2,b'old')+packed(2,b'new'),
                  b'\x08\x81\0'+packed(2,b'x')]:
        valid(packed(1,entry))
    valid(packed(1,b'\x08\x01'+packed(2,b'old'))+packed(1,b'\x08\x01'))
    # Message members merge within one entry. Separate entries with the same key
    # replace the complete value, including with an absent value/empty message.
    first = b'\x08\x01'+packed(2,proto.Packet(count=5).SerializeToString())
    second = b'\x08\x01'+packed(2,proto.Packet(code=7).SerializeToString())
    valid(packed(5,first+packed(2,proto.Packet(code=7).SerializeToString())))
    valid(packed(5,first)+packed(5,second))
    valid(packed(5,first)+packed(5,b'\x08\x01'))
    valid(packed(5,first)+packed(5,b'\x08\x01'+packed(2,b'')))
    valid(packed(1,packed(5,first))+packed(1,packed(5,second)), '/maps-envelope')
    # Unknown outer fields and wrong outer wire kinds must not create entries.
    valid(b'\x08\x01'+packed(99,b'unknown')+packed(1,b''))
    # Unknown entry members, wrong key/value wire kinds, and unknown groups.
    for entry in [b'\x18\x01', b'\x0a\x00', b'\x10\x01', b'\x1b\x20\x01\x1c']:
        valid(packed(1,entry))
    for size in [255,256,257]:
        data = packed(3, packed(2,b'x'*(size-3)))
        if size <= 256:
            valid(data)
        else:
            assert call('/maps',data) == (400,b'FieldLimit')
    for count in [63,64,65]:
        data = packed(1,b'')*32 + packed(3,b'')*(count-32)
        if count <= 64:
            valid(data)
        else:
            assert call('/maps',data) == (400,b'EntryLimit')
    # Input limit is checked before field traversal; bounded unknown byte
    # fields fill the input without exhausting tag/materialization budgets.
    for size in [4095,4096,4097]:
        prefix = packed(99,b'x'*256)*15
        data = prefix + packed(99,b'x'*(size-len(prefix)-4))
        assert len(data) == size
        if size <= 4096:
            valid(data)
        else:
            assert call('/maps',data) == (400,b'InputLimit')
    # Shared tag budget, with no collection growth from unknown fields.
    for count in [255,256,257]:
        data = packed(1,b'')+b'\x78\0'*(count-1)
        if count <= 256:
            valid(data)
        else:
            assert call('/maps',data) == (400,b'TagLimit')
    # Entry depth is one; a message value requires a second scope.
    valid(packed(1,b''),'/maps-depth')
    valid(packed(5,b''),'/maps-depth')
    assert call('/maps-depth',packed(5,packed(2,b''))) == (400,b'DepthLimit')
    # Materialization charges replaced values as well as retained values.
    for size in [15,16,17]:
        data = packed(3,packed(2,b'a'*8))+packed(3,packed(2,b'b'*(size-8)))
        if size <= 16:
            valid(data,'/maps-material')
        else:
            assert call('/maps-material',data) == (400,b'MaterializationLimit')
    # Output entries omit scalar defaults; this fixture uses a nondefault key.
    for size in [15,16,17]:
        data = packed(1,b'\x08\x01'+packed(2,b'x'*(size-6)))
        if size <= 16:
            valid(data,'/maps-output')
        else:
            assert call('/maps-output',data) == (400,b'OutputLimit')
    for data,error in [(b'\x0a\x01',b'Truncated'),(packed(1,b'\x08\x80'),b'Truncated'),
                       (packed(1,packed(2,b'\xff')),b'InvalidUtf8'),
                       (packed(1,b'\x08'+b'\xff'*9+b'\x02'),b'VarintOverflow')]:
        assert call('/maps',data) == (400,error)
    status, wire = call('/maps-construct',b'')
    assert status == 200, wire
    actual = proto.MapPacket.FromString(wire)
    expected = proto.MapPacket(signed32={-1:'new',0:''}, signed64={-(1<<63):-7},
                              unsigned32={(1<<32)-1:b'\0\xff'}, unsigned64={(1<<64)-1:'heap-backed map value 🐦'},
                              zigzag32={-(1<<31):-2}, zigzag64={-(1<<63):-3}, fixed32={(1<<32)-1:-1.5},
                              fixed64={(1<<64)-1:2.5}, sfixed32={-(1<<31):True}, sfixed64={-(1<<63):(1<<64)-1})
    expected.flags[False].CopyFrom(proto.Packet())
    expected.flags[True].count = 7
    expected.strings[''].CopyFrom(proto.Packet())
    expected.strings['heap-backed map key 🐦'].code = 9
    assert actual == expected, (actual,expected)
