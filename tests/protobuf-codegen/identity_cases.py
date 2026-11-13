"""Generated nested and imported nominal types against official Python bindings."""


def verify_identities(call, reference, catalog):
    cases = [
        (0, reference.Envelope.Payload, [b'', b'\x0a\x00', b'\x0a\x03abc',
                                       b'\x0a\x03old\x0a\x00', b'\x08\x01'],
         reference.Envelope.Payload(text='nested 🐦')),
        (1, catalog.Entry, [b'', b'\x08\x00', b'\x08\x7f', b'\x08\x80\x01',
                            b'\x08\x81\x01', b'\x08\x01\x08\x00', b'\x0a\x00'],
         catalog.Entry(count=(1 << 64) - 1)),
        (2, catalog.Entry.Detail, [b'', b'\x0a\x00', b'\x0a\x03\x00\x80\xff',
                                   b'\x0a\x01x\x0a\x00', b'\x08\x01'],
         catalog.Entry.Detail(payload=b'\x00\x80\xff')),
    ]
    for selector, message_type, inputs, constructed in cases:
        prefix = bytes([selector])
        for data in inputs:
            expected = message_type.FromString(data)
            # Roc intentionally discards unknown and wrong-wire-type fields.
            expected.DiscardUnknownFields()
            status, encoded = call('/identity-copy', prefix + data)
            assert status == 200, (selector, data, status, encoded)
            actual = message_type.FromString(encoded)
            assert actual == expected, (selector, actual, expected)
            if selector == 0:
                view = ('present:' + expected.text if expected.HasField('text') else 'absent').encode()
                assert actual.HasField('text') == expected.HasField('text')
            elif selector == 1:
                view = str(expected.count).encode()
            else:
                view = expected.payload
            assert call('/identity-view', prefix + data) == (200, view)
        status, encoded = call('/identity-construct', prefix)
        assert status == 200
        assert message_type.FromString(encoded) == constructed
        # A complete tag followed by no value is malformed for each field kind.
        tag = b'\x08' if selector == 1 else b'\x0a'
        assert call('/identity-copy', prefix + tag) == (400, b'Truncated')
    assert call('/identity-empty', b'') == (200, b'')
    assert call('/identity-empty', b'\x08\x01') == (200, b'')
    assert call('/identity-empty', b'\x08') == (400, b'Truncated')
