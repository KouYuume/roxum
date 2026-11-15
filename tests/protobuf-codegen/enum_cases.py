"""Open enum values, aliases, presence, packing and shared limits."""
from scalar_cases import varint
from unsigned_cases import packed


def verify_enums(call, proto):
    def valid(data, path='/enum'):
        kind = proto.EnumEnvelope if path == '/enum-envelope' else proto.EnumPacket
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        status, wire = call(path, data)
        assert status == 200, (data.hex(), status, wire)
        assert kind.FromString(wire) == expected
        if kind == proto.EnumPacket:
            presence = str(expected.selected) if expected.HasField('selected') else 'absent'
            view = f'{expected.state};{presence};{",".join(map(str, expected.states))};{",".join(map(str, expected.expanded))};{expected.mode}'
            assert call('/enum-view', data) == (200, view.encode())
            assert wire == expected.SerializeToString()
        return wire

    valid(b'')
    for n in [-(1 << 31), -(1 << 31)+1, -2, -1, 0, 1, 2, (1 << 31)-2, (1 << 31)-1]:
        raw = varint(n & ((1 << 64)-1))
        valid(proto.EnumPacket(state=n, selected=n, states=[0,n,1], expanded=[n,0], mode=n).SerializeToString())
        valid(b'\x18'+raw+packed(3, raw)+packed(3,b'')+b'\x20'+raw+packed(4,raw))
    for raw in [(1 << 32)-1, 1 << 32, (1 << 32)+1, (1 << 64)-1]:
        value = varint(raw)
        valid(b'\x08'+value+b'\x10'+value+packed(3,value))
    valid(b'\x08\x81\x00\x10\x80\x00')
    valid(b'\x0a\x01x\x15\0\0\0\0')
    valid(b'\x08\x01\x10\x01\x08\0\x10\0')
    status, wire = call('/enum-construct', b'')
    assert status == 200
    assert proto.EnumPacket.FromString(wire) == proto.EnumPacket(state=-1, selected=0, states=[1,1,-(1 << 31)], expanded=[(1 << 31)-1], mode=1)
    for count in [63,64,65]:
        data = packed(3,b'\x01'*32)+b'\x20\x02'*(count-32)
        if count <= 64:
            valid(data)
        else:
            assert call('/enum',data) == (400,b'EntryLimit')
    for count in [127,128,129]:
        data = packed(3,b'')*count
        if count <= 128:
            valid(data)
        else:
            assert call('/enum',data) == (400,b'TagLimit')
    for payload,error in [(b'\x80',b'Truncated'), (b'\xff'*9+b'\x02',b'VarintOverflow')]:
        for data in [b'\x08'+payload,b'\x10'+payload,packed(3,payload)+b'\x08\0']:
            assert call('/enum',data) == (400,error)
    first = proto.EnumPacket(state=1, selected=1, states=[1]).SerializeToString()
    last = b'\x08\0\x10\0'+packed(3,b'\x02')
    valid(packed(1,first)+packed(1,last),'/enum-envelope')
    assert call('/enum-envelope',packed(1,b'\x1a\x02\x80')+packed(1,b'')) == (400,b'Truncated')
    for size in [15,16,17]:
        data = packed(3,b'\x01'*(size-2))
        if size <= 16:
            valid(data,'/enum-output')
        else:
            assert call('/enum-output',data) == (400,b'OutputLimit')
