"""Message occurrences append distinct values and share all reader budgets."""
from scalar_cases import varint


def verify_message_lists(call, proto):
    def child(data):
        return b'\x0a' + varint(len(data)) + data

    def valid(data, path='/message-list'):
        status, wire = call(path, data)
        assert status == 200, (status, wire)
        kind = proto.MessageListEnvelope if path == '/message-list-envelope' else proto.MessageList
        expected = kind.FromString(data)
        expected.DiscardUnknownFields()
        assert kind.FromString(wire) == expected

    empty = proto.Collections()
    a = proto.Collections(texts=['a'])
    status, wire = call('/message-list-construct', b'')
    assert status == 200
    assert proto.MessageList.FromString(wire) == proto.MessageList(children=[empty, a, empty])
    for value in [proto.MessageList(), proto.MessageList(children=[empty]),
                  proto.MessageList(children=[a, empty, empty]),
                  proto.MessageList(children=[a, a]),
                  proto.MessageList(children=[a, proto.Collections(chunks=[b'\xff'])])]:
        valid(value.SerializeToString())
    first = child(a.SerializeToString())
    last = child(proto.Collections(chunks=[b'z']).SerializeToString())
    # Parent merging appends child elements; an empty parent retains the list.
    valid(child(first) + child(b'') + child(last), '/message-list-envelope')
    valid(b'\x08\x01' + first + b'\x12\x01x')
    # Empty messages still consume one entry each.
    for count in [3, 4, 5]:
        data = child(b'') * count
        if count <= 4:
            valid(data)
        else:
            assert call('/message-list', data) == (400, b'EntryLimit')
    # Child collection entries and message entries use the same counter.
    for total in [3, 4, 5]:
        data = child(proto.Collections(texts=['']*(total-1)).SerializeToString())
        if total <= 4:
            valid(data)
        else:
            assert call('/message-list', data) == (400, b'EntryLimit')
    for data, error in [(child(b'\x0a\x02x'), b'Truncated'),
                        (child(b'\x0a\x01\xff'), b'InvalidUtf8'),
                        (child(b'\x0c'), b'UnexpectedEndGroup')]:
        assert call('/message-list', data + child(b'')) == (400, error)
    # Depth: message at one, parent plus message at two, plus unknown group at three.
    valid(first)
    valid(child(first), '/message-list-envelope')
    assert call('/message-list-envelope', child(child(b'\x1b\x1c'))) == (400, b'DepthLimit')
    for size in [255, 256, 257]:
        payload = b'\x1a' + varint(size-3) + b'x'*(size-3)
        assert len(payload) == size
        data = child(payload)
        if size <= 256:
            valid(data)
        else:
            assert call('/message-list', data) == (400, b'FieldLimit')
    # Two message entries and two payload entries share materialization across siblings.
    for total in [511, 512, 513]:
        data = child(proto.Collections(texts=['x'*130]).SerializeToString())
        data += child(proto.Collections(chunks=[b'y'*(total-260)]).SerializeToString())
        if total <= 512:
            valid(data)
        else:
            assert call('/message-list', data) == (400, b'MaterializationLimit')
    for size in [15, 16, 17]:
        data = proto.MessageList(children=[empty, proto.Collections(chunks=[b'x'*(size-6)])]).SerializeToString()
        assert len(data) == size
        status, wire = call('/message-list-output', data)
        if size <= 16:
            assert status == 200 and proto.MessageList.FromString(wire) == proto.MessageList.FromString(data)
        else:
            assert (status, wire) == (400, b'OutputLimit')
    valid(b'')
