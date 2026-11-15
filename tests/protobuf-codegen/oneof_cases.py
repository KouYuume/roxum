"""Selection, merge, replacement, and retained union payloads versus Python."""
import math
import struct
from unsigned_cases import packed


def view(value):
    name = value.WhichOneof('choice')
    if name is None:
        selection = 'unset'
    elif name in ['float_value', 'double_value']:
        selection = name
    else:
        item = getattr(value, name)
        if name == 'payload':
            item = ','.join(map(str,item))
        elif name == 'enabled':
            item = str(item).lower()
        elif name in ['child_value','other_child']:
            item = f'{item.text}|{",".join(map(str,item.numbers))}|{len(item.labels)}'
        selection = f'{name}:{item}'
    secondary = 'unset' if value.WhichOneof('secondary') is None else 'extra:'+','.join(map(str,value.extra))
    marker = str(value.marker) if value.HasField('marker') else 'absent'
    return f'{selection}/{secondary}/{marker}/{value.outside}'


def verify_oneofs(call, proto):
    def valid(data, path='/choice'):
        kind = proto.ChoiceEnvelope if path == '/choice-envelope' else proto.ChoicePacket
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        status, wire = call(path,data)
        assert status == 200, (path,data.hex(),status,wire)
        actual = kind.FromString(wire)
        assert actual == expected, (data.hex(),actual,expected)
        if kind == proto.ChoicePacket:
            assert actual.WhichOneof('choice') == expected.WhichOneof('choice')
            assert actual.WhichOneof('secondary') == expected.WhichOneof('secondary')
            assert call('/choice-view',data) == (200,view(expected).encode())
            cleared = proto.ChoicePacket()
            cleared.CopyFrom(expected)
            cleared.ClearField('choice')
            cleared.ClearField('secondary')
            assert call('/choice-retained',data) == (200,f'{view(expected)};{view(cleared)};{view(expected)}'.encode())
        return wire

    valid(b'')
    members = proto.ChoicePacket.DESCRIPTOR.oneofs_by_name['choice'].fields
    encoded = []
    for field in members:
        packet = proto.ChoicePacket()
        # Every selected default is distinct from Unset, including empty children.
        if field.message_type:
            getattr(packet,field.name).CopyFrom(proto.ChoiceChild())
        else:
            setattr(packet,field.name,field.default_value)
        raw = packet.SerializeToString()
        assert raw
        valid(raw)
        encoded.append(raw)
    # Every case can replace every other case; independent groups and optional
    # presence retain their own state across the switch.
    suffix = proto.ChoicePacket(extra=b'',marker=0,outside=7).SerializeToString()
    for first in encoded:
        for last in encoded:
            valid(first+suffix+last)
    for name,values in {
        'unsigned64':[1,(1<<64)-2,(1<<64)-1], 'unsigned32':[1,(1<<32)-2,(1<<32)-1],
        'signed32':[-(1<<31),-(1<<31)+1,-1,1,(1<<31)-2,(1<<31)-1],
        'signed64':[-(1<<63),-(1<<63)+1,-1,1,(1<<63)-2,(1<<63)-1],
        'zigzag32':[-(1<<31),-(1<<31)+1,-1,1,(1<<31)-2,(1<<31)-1], 'zigzag64':[-(1<<63),-(1<<63)+1,-1,1,(1<<63)-2,(1<<63)-1],
        'fixed32_value':[1,(1<<32)-2,(1<<32)-1], 'fixed64_value':[1,(1<<64)-2,(1<<64)-1],
        'signed_fixed32':[-(1<<31),-(1<<31)+1,-1,1,(1<<31)-2,(1<<31)-1], 'signed_fixed64':[-(1<<63),-(1<<63)+1,-1,1,(1<<63)-2,(1<<63)-1],
        'enabled':[True], 'text':['heap-backed oneof string 🐦'*2], 'payload':[b'heap-backed payload'*2],
        'state':[-(1<<31),-1,1,2,(1<<31)-1],
    }.items():
        for value in values:
            valid(proto.ChoicePacket(**{name:value}).SerializeToString())
    for name,fmt in [('float_value','<f'),('double_value','<d')]:
        for number in [-0.0,1.5,float('inf'),-float('inf'),float('nan')]:
            data=proto.ChoicePacket(**{name:number}).SerializeToString()
            status,wire=call('/choice',data)
            assert status == 200,wire
            result=proto.ChoicePacket.FromString(wire)
            assert result.WhichOneof('choice') == name
            actual=getattr(result,name)
            assert math.isnan(actual) if math.isnan(number) else struct.pack(fmt,actual)==struct.pack(fmt,number)
    first=packed(17,proto.ChoiceChild(text='heap-backed message value',numbers=[1],labels={'a':1}).SerializeToString())
    last=packed(17,proto.ChoiceChild(numbers=[2],labels={'b':2}).SerializeToString())
    valid(first+last)
    valid(first+packed(17,b''))
    valid(first+packed(17,packed(1,b'')))
    valid(first+packed(18,b'')+last)
    valid(first+b'\x08\0'+last)
    valid(packed(1,first)+packed(1,last),'/choice-envelope')
    valid(packed(1,first)+packed(1,b'\x08\0')+packed(1,last),'/choice-envelope')
    # Unknown and wrong-wire fields do not switch the active case. Nonminimal
    # values remain accepted; unknown fields are not retained on re-encoding.
    valid(first+packed(16,b'x')+packed(99,b'unknown')+b'\x08\x81\0')
    valid(first+packed(16,b'x')+packed(99,b'unknown'))
    # Collection work is charged even when a later case discards the child.
    for count in [63,64,65]:
        data=packed(17,packed(2,b'\x01'*32))+packed(17,packed(2,b'\x01'*(count-32)))+b'\x08\0'
        if count<=64: valid(data)
        else: assert call('/choice',data)==(400,b'EntryLimit')
    for count in [127,128,129]:
        data=b'\x08\0'*count
        if count<=128: valid(data)
        else: assert call('/choice',data)==(400,b'TagLimit')
    for size in [15,16,17]:
        data=packed(13,b'a'*8)+packed(19,b'b'*(size-8))+b'\x08\0'
        if size<=16: valid(data,'/choice-material')
        else: assert call('/choice-material',data)==(400,b'MaterializationLimit')
        data=packed(13,b'x'*(size-2))
        if size<=16: valid(data,'/choice-output')
        else: assert call('/choice-output',data)==(400,b'OutputLimit')
    for size in [255,256,257]:
        data=packed(13,b'x'*size)
        if size<=256: valid(data)
        else: assert call('/choice',data)==(400,b'FieldLimit')
    for size in [4095,4096,4097]:
        prefix=packed(99,b'x'*256)*15
        data=prefix+packed(99,b'x'*(size-len(prefix)-4))
        assert len(data)==size
        if size<=4096: valid(data)
        else: assert call('/choice',data)==(400,b'InputLimit')
    valid(b'','/choice-depth')
    valid(b'\x08\0','/choice-depth')
    assert call('/choice-depth',packed(17,b''))==(400,b'DepthLimit')
    for data,error in [(b'\x08\x80',b'Truncated'),(packed(12,b'\xff'),b'InvalidUtf8'),
                       (packed(17,b'\x0a\x02x'),b'Truncated'),(b'\x08'+b'\xff'*9+b'\x02',b'VarintOverflow')]:
        assert call('/choice',first+data)==(400,error)
    status,wire=call('/choice-construct',b'')
    assert status==200
    assert proto.ChoicePacket.FromString(wire)==proto.ChoicePacket(state=-7,extra=b'',marker=0,outside=9)
