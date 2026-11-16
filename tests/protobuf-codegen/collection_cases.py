"""Repeated length-delimited fields preserve order and share logical budgets."""
from scalar_cases import varint


def verify_collections(call, proto):
    def valid(data, path='/collections'):
        status, wire = call(path, data)
        assert status == 200, (status, wire)
        kind = proto.CollectionEnvelope if path == '/collection-envelope' else proto.Collections
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        assert kind.FromString(wire) == expected

    def child(data):
        return b'\x0a' + varint(len(data)) + data

    status, wire = call('/collections-construct', b'')
    assert status == 200
    assert proto.Collections.FromString(wire) == proto.Collections(texts=['', 'hello', ''], chunks=[b'', b'\x00\xff'])
    for value in [proto.Collections(), proto.Collections(texts=['', 'hello', '🐦', '']),
                  proto.Collections(chunks=[b'', b'\x00\xff', b'', b'x']),
                  proto.Collections(texts=['a', 'a'], chunks=[b'x', b'x'])]:
        valid(value.SerializeToString())
    # Interleaving and unknown/wrong-wire fields must not reorder or add entries.
    valid(b'\x12\x01x\x0a\x01a\x08\x01\x1a\x01z\x0a\x00\x12\x00')
    # One entry budget is shared across field kinds and merged child occurrences.
    for count in [3, 4, 5]:
        data = b'\x0a\x00' * (count-1) + b'\x12\x00'
        nested = child(data[:-2]) + child(data[-2:])
        for path, body in [('/collections', data), ('/collection-envelope', nested)]:
            if count <= 4:
                valid(body, path)
            else:
                assert call(path, body) == (400, b'EntryLimit')
    # Payload length boundaries; each string byte charges read and UTF-8 conversion.
    for size in [255, 256, 257]:
        for tag in [b'\x0a', b'\x12']:
            data = tag + varint(size) + b'x'*size
            if size <= 256:
                valid(data)
            else:
                assert call('/collections', data) == (400, b'FieldLimit')
    for total in [511, 512, 513]:
        data = proto.Collections(texts=['x'*127], chunks=[b'y'*256, b'z'*(total-510)]).SerializeToString()
        if total <= 512:
            valid(data)
        else:
            assert call('/collections', data) == (400, b'MaterializationLimit')
    for data, error in [(b'\x0a', b'Truncated'), (b'\x12\x02x', b'Truncated'),
                        (b'\x0a\x01\xff', b'InvalidUtf8')]:
        assert call('/collections', data) == (400, error)
    # Empty elements are emitted too; the complete output is bounded.
    for total in [15, 16, 17]:
        data = proto.Collections(texts=[''], chunks=[b'x'*(total-4)]).SerializeToString()
        assert len(data) == total
        status, wire = call('/collections-output', data)
        if total <= 16:
            assert status == 200 and proto.Collections.FromString(wire) == proto.Collections.FromString(data)
        else:
            assert (status, wire) == (400, b'OutputLimit')
    valid(b'')
