"""Packed scalar payload boundaries without schema or message-depth changes."""

def verify_packed(client, varint):
    def check(path, data, expected):
        client.request('POST', path, data)
        response = client.getresponse()
        actual = response.status, response.read()
        assert actual == expected, (path, data.hex(), actual, expected)

    def block(payload):
        return varint(len(payload)) + payload

    for suffix, width in [('varints', 0), ('fixed32', 4), ('fixed64', 8)]:
        path = '/packed-' + suffix
        encode = varint if not width else lambda n: n.to_bytes(width, 'little')
        values = [0, 1, 127, 128, (1 << (width*8 if width else 64))-1]
        payload = b''.join(map(encode, values))
        check(path, block(payload), (200, payload))
        check(path, block(b'') + block(payload) + block(b''), (200, payload))
        # The same entry counter must survive multiple packed payloads.
        for count in [63, 64, 65]:
            data = b''.join(block(encode(1) * min(32, count-offset)) for offset in range(0, count, 32))
            check(path, data, (200, encode(1)*count) if count <= 64 else (400, b'EntryLimit'))
        check(path, b'\x02\x01', (400, b'Truncated'))
        if width:
            for size in [width-1, width, width+1]:
                check(path, block(b'\0'*size) + block(b'\0'*width),
                      (200, b'\0'*(2*width)) if size == width else (400, b'Truncated'))
    check('/packed-varints', block(b'\x80\x00\xff\x00'), (200, b'\x00\x7f'))
    check('/packed-varints', block(b'\x80') + b'\x01\x00', (400, b'Truncated'))
    check('/packed-varints', block(b'\xff'*9+b'\x02'), (400, b'VarintOverflow'))
    # A 256-byte fixed64 payload is valid; nearby lengths exercise alignment and field cap.
    for size, expected in [(255, (400, b'Truncated')), (256, (200, b'\0'*256)),
                           (257, (400, b'FieldLimit'))]:
        check('/packed-fixed64', block(b'\0'*size), expected)
    # Empty segments consume input, but no entries or materialized bytes.
    for size in [4095, 4096, 4097]:
        check('/packed-varints', b'\0'*size, (200, b'') if size <= 4096 else (400, b'InputLimit'))
