"""Typed dictionary layouts; no Protobuf wire semantics are claimed here."""


def signed(value, bits):
    value %= 1 << bits
    return value if value < 1 << (bits - 1) else value - (1 << bits)


def keys_for(raw):
    return {
        'signed32': str(signed(raw, 32)),
        'signed64': str(signed(raw, 64)),
        'unsigned32': str(raw % (1 << 32)),
        'unsigned64': str(raw),
        'flags': 'true' if raw % 2 else 'false',
        'strings': f'map key {raw} with heap storage 🐦' if raw else '',
    }


def expected(words, replace=False):
    entries = {}
    for index, raw in enumerate(words):
        text = f'map payload {raw} at {index} 🐦'
        payload = f'{raw % 256},{index},255'
        values = dict(signed32=f'{text}/{payload}', signed64=str(signed(raw, 32)),
                      unsigned32=payload, unsigned64=text,
                      flags=f'{text}/{payload}', strings=f'{text}/{payload}')
        for kind, key in keys_for(raw).items():
            entries[kind, key] = values[kind]
    if replace:
        values = dict(signed32='replacement/', signed64='0', unsigned32='',
                      unsigned64='', flags='replacement/', strings='replacement/')
        for kind, key in keys_for(words[-1] if words else 0).items():
            entries[kind, key] = values[kind]
    return {f'{kind}:{key}={value}~{value}' for (kind, key), value in entries.items()}


def verify_maps(call):
    def check(words):
        status, body = call('/maps', b''.join(word.to_bytes(8, 'little') for word in words))
        assert status == 200, (words, status, body)
        snapshots = body.decode().split(';')
        assert len(snapshots) == 3, body
        for snapshot, replace in zip(snapshots, [False, True, False]):
            lines = snapshot.splitlines()
            wanted = expected(words, replace)
            assert len(lines) == len(wanted), (words, lines, wanted)
            assert set(lines) == wanted, (words, lines, wanted)

    # Empty maps, defaults, and both bool keys. Replacement of an empty map
    # inserts defaults; replacement of a present key preserves the original.
    for words in [[], [0], [1], [0, 1], [1, 0], [0, 0], [1, 1]]:
        check(words)
    # Nearest values on both sides of signed and unsigned width transitions;
    # conversion to I32/U32 intentionally makes some distinct U64 keys collide.
    boundaries = [0, 1]
    for boundary in [1 << 31, 1 << 32, 1 << 63]:
        boundaries.extend([boundary - 1, boundary, boundary + 1])
    boundaries.extend([(1 << 64) - 2, (1 << 64) - 1])
    for raw in boundaries:
        check([raw])
    check(boundaries + list(reversed(boundaries)))
    # Distinct heap-backed keys/values grow dictionaries; duplicate keys replace
    # values while retaining the pre-replacement dictionaries for observation.
    for count in [2, 8, 16, 32, 63, 64]:
        check(list(range(count)))
        check([0] * count)
    assert call('/maps', b'\0' * (65 * 8)) == (400, b'EntryLimit')
    # Exactly whole eight-byte words are accepted, including empty input.
    for size in [1, 7, 9, 511, 513]:
        assert call('/maps', b'\0' * size) == (400, b'InputLength')
    # Repeat allocation and replacement across request lifetimes with changing
    # heap keys and values, including signed extremes and full dictionaries.
    for offset in range(16):
        check([(1 << 63) + offset + index for index in range(64)])
