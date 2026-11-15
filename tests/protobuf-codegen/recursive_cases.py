"""Recursive values, sharing, merge, and independently bounded encoder traversal."""
from unsigned_cases import packed


def verify_recursive(call, proto):
    def stats(node):
        children = list(node.children) + list(node.lookup.values())
        if node.HasField('next'): children.append(node.next)
        if node.WhichOneof('choice') == 'selected': children.append(node.selected)
        nested = [stats(child) for child in children]
        return 1 + sum(n for n,_ in nested), node.value + sum(v for _,v in nested)

    def valid(data, path='/recursive'):
        kind = proto.RecursiveEnvelope if path == '/recursive-envelope' else proto.RecursiveNode
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        status, wire = call(path,data)
        assert status == 200, (path,data.hex(),status,wire)
        assert kind.FromString(wire) == expected, (data.hex(),wire.hex(),expected)
        if kind == proto.RecursiveNode:
            before = ','.join(map(str,stats(expected)))
            changed = f'1,{expected.value}'
            wanted = f'{before};{changed};{before}'.encode()
            assert call('/recursive-retained',data) == (200,wanted)
        return wire

    valid(b'')
    # Every recursive edge form is tested: presence, list, union and map value.
    for field in [2,3,4]:
        for depth in [0,1,2,7,8,9]:
            data = b'\x08\x07'
            for _ in range(depth): data = packed(field,data)
            if depth <= 8: valid(data)
            else: assert call('/recursive',data) == (400,b'DepthLimit')
    for depth in [3,4,5]:
        data = b''
        for _ in range(depth): data = packed(6,packed(1,b'key')+packed(2,data))
        if depth <= 4: valid(data)
        else: assert call('/recursive',data) == (400,b'DepthLimit')
    # Mutually recursive identities cross alternating types and enter through
    # an acyclic wrapper. Branch values distinguish the two nominal layouts.
    for depth in [0,1,2,6,7,8]:
        data = b'\x08\x07'
        for index in range(depth): data = b'\x08'+bytes([index+1])+packed(2,data)
        wire = packed(2,data)
        if depth <= 7: valid(wire,'/recursive-envelope')
        else: assert call('/recursive-envelope',wire) == (400,b'DepthLimit')
    # Duplicate recursive messages merge; a case switch discards the old child.
    first = b'\x08\x01'+packed(3,b'\x08\x02')
    last = packed(3,b'\x08\x03')
    valid(packed(2,first)+packed(2,last))
    valid(packed(4,first)+packed(4,last))
    valid(packed(4,first)+packed(5,b'changed')+packed(4,last))
    valid(packed(6,packed(1,b'key')+packed(2,first))+packed(6,packed(1,b'key')+packed(2,last)))
    valid(packed(6,b''))
    # Encoding has independent depth and total visited-message limits. Roots
    # and empty children consume work; sibling visits do not restore work.
    for depth in [2,3,4]:
        data = b''
        for _ in range(depth): data = packed(2,data)
        if depth <= 3: valid(data,'/recursive-depth')
        else: assert call('/recursive-depth',data) == (400,b'DepthLimit')
    for count in [3,4,5]:
        data = packed(3,b'')*(count-1)
        if count <= 4: valid(data,'/recursive-work')
        else: assert call('/recursive-work',data) == (400,b'MessageLimit')
    # A map entry is itself a message visit, even with both members omitted.
    valid(packed(6,b''),'/recursive-work')
    assert call('/recursive-work',packed(6,packed(1,b'a'))+packed(6,packed(1,b'b'))) == (400,b'MessageLimit')
    # The Roc constructor retains shared subtrees; logical visits, not unique
    # allocation identities, must limit this exponential encoding workload.
    for depth in [0,1,2,3,4,64]:
        status, wire = call('/recursive-construct',bytes([depth]))
        if depth <= 3:
            assert status == 200, wire
            assert stats(proto.RecursiveNode.FromString(wire)) == (2**(depth+1)-1,0)
        else: assert (status,wire) == (400,b'MessageLimit')
    for data,error in [(b'',b'InputLength'),(b'\0\0',b'InputLength'),(bytes([65]),b'DepthLimit')]:
        assert call('/recursive-construct',data) == (400,error)
    # Both default encoder and decoder accept the nearest depth below and at
    # 64, and reject 65. The constructor builds a linear chain in O(depth).
    for depth in [63,64,65]:
        status, wire = call('/recursive-chain',bytes([depth]))
        data = b''
        for _ in range(depth): data = packed(2,data)
        if depth <= 64:
            assert status == 200, wire
            assert proto.RecursiveNode.FromString(wire) == proto.RecursiveNode.FromString(data)
            status, output = call('/recursive-defaults',data)
            assert status == 200, output
            assert proto.RecursiveNode.FromString(output) == proto.RecursiveNode.FromString(data)
        else:
            assert (status,wire) == (400,b'DepthLimit')
            assert call('/recursive-defaults',data) == (400,b'DepthLimit')
    # A nested truncated message cannot consume the next parent's bytes.
    assert call('/recursive',packed(2,b'\x12\x02\x08')+b'\x08\x01') == (400,b'Truncated')
    # Root is the first message visit, even for the empty default value.
    # Decoder resource budgets remain shared through recursive replacements.
    for count in [127,128,129]:
        data = packed(3,b'')*count
        if count <= 128: valid(data)
        else: assert call('/recursive',data) == (400,b'EntryLimit')
