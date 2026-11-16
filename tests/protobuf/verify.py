#!/usr/bin/env python3
"""Wire differential checks; this is not generated-schema interoperability."""
import http.client
import pathlib
import random
import subprocess
import sys
import tempfile
from packed_cases import verify_packed

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import read_port, stop


def varint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


class Invalid(Exception):
    pass


def reference(data, discard):
    """Independent integer-arithmetic decoder with the fixture's fixed limits."""
    pos = tags = entries = copied = 0
    groups = []
    output = bytearray()

    def fail(reason):
        raise Invalid(reason)

    def read_varint():
        nonlocal pos
        value = 0
        for index in range(10):
            if pos == len(data):
                fail('Truncated')
            byte = data[pos]
            pos += 1
            if index == 9 and byte > 1:
                fail('VarintOverflow')
            value += (byte & 127) * (128 ** index)
            if byte < 128:
                return value
        fail('VarintOverflow')

    try:
        if len(data) > 4096:
            fail('InputLimit')
        while pos < len(data):
            if tags == 128:
                fail('TagLimit')
            tags += 1
            tag = read_varint()
            number, wire = divmod(tag, 8)
            if not 1 <= number <= (1 << 29) - 1:
                fail('InvalidTag')
            if wire > 5:
                fail('InvalidWireType')
            if wire == 3:
                if len(groups) == 8:
                    fail('DepthLimit')
                groups.append(number)
                continue
            if wire == 4:
                if not groups:
                    fail('UnexpectedEndGroup')
                if groups.pop() != number:
                    fail('MismatchedGroup')
                continue
            emit = not discard and not groups
            if emit:
                if entries == 64:
                    fail('EntryLimit')
                entries += 1
            if wire == 0:
                encoded = varint(read_varint())
            else:
                length = read_varint() if wire == 2 else {1: 8, 5: 4}[wire]
                if wire == 2 and length > 256:
                    fail('FieldLimit')
                if length > len(data) - pos:
                    fail('Truncated')
                if emit and wire == 2:
                    if copied + length > 512:
                        fail('MaterializationLimit')
                    copied += length
                encoded = (varint(length) if wire == 2 else b'') + data[pos:pos + length]
                pos += length
            if emit:
                output += varint(tag) + encoded
        if groups:
            fail('UnclosedGroup')
        return 200, bytes(output)
    except Invalid as error:
        return 400, str(error).encode()


def cases():
    # Exact wire examples and every truncation of them.
    seeds = [b'', b'\x08\x96\x01', b'\x0a\x03abc', b'\x09' + bytes(range(8)),
             b'\x0d' + bytes(range(4)), b'\x0b\x13\x18\x01\x14\x0c']
    for seed in seeds:
        for length in range(len(seed) + 1):
            yield seed[:length]
    # Integer-width boundaries and maximum tenth-byte payload.
    for shift in range(7, 64, 7):
        for value in [(1 << shift) - 1, 1 << shift, (1 << shift) + 1]:
            yield b'\x08' + varint(value)
    for final in [0, 1, 2, 127, 128, 255]:
        yield b'\x08' + b'\xff' * 9 + bytes([final])
    # Non-minimal value and tag encodings are legal.
    yield b'\x88\x00\x80\x00'
    for raw in [0, 7, 8, 9, 14, 15, (1 << 32) - 3, 1 << 32]:
        yield varint(raw) + b'\0' * 8
    # Limit-1 / limit / limit+1, including discarded values and group delimiters.
    for size in [255, 256, 257]:
        yield b'\x0a' + varint(size) + b'x' * size
    for copied in [511, 512, 513]:
        yield (b'\x0a\x80\x02' + b'x' * 256 + b'\x12\xff\x01' + b'y' * 255
               + b'\x1a' + varint(copied - 511) + b'z' * (copied - 511))
    for count in [63, 64, 65, 127, 128, 129]:
        yield b'\x08\0' * count
    for depth in [7, 8, 9]:
        yield b'\x0b' * depth + b'\x0c' * depth
    yield b'\x0b\x14'
    for size in [4095, 4096, 4097]:
        yield b'\x08\0' * (size // 2) + (b'\0' if size % 2 else b'')
    rng = random.Random(424242)
    # Structured valid streams exercise deeper paths than arbitrary bytes alone.
    for _ in range(200):
        stream = bytearray()
        for _ in range(rng.randrange(1, 20)):
            wire = rng.choice([0, 1, 2, 5])
            stream += varint(rng.randint(1, (1 << 29) - 1) * 8 + wire)
            if wire == 0:
                stream += varint(rng.getrandbits(64))
            else:
                size = rng.randrange(0, 40) if wire == 2 else {1: 8, 5: 4}[wire]
                stream += (varint(size) if wire == 2 else b'') + bytes(rng.randrange(256) for _ in range(size))
        yield bytes(stream)
        if len(stream) > 1:
            yield bytes(stream[:rng.randrange(1, len(stream))])
    for _ in range(200):
        yield bytes(rng.randrange(256) for _ in range(rng.randrange(64)))


def main():
    # Known outputs keep the oracle itself accountable.
    assert reference(b'\x88\x00\x96\x81\x00', False) == (200, b'\x08\x96\x01')
    assert reference(b'\x0b\x14', False) == (400, b'MismatchedGroup')
    assert reference(b'\x0a\x01\xff', False) == (200, b'\x0a\x01\xff')
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as log:
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                  stderr=log, text=True, start_new_session=True)
        client = None
        try:
            client = http.client.HTTPConnection('127.0.0.1', read_port(server), timeout=10)
            count = 0
            for data in cases():
                for discard in [False, True]:
                    client.request('POST', '/skip' if discard else '/copy', data)
                    response = client.getresponse()
                    actual = response.status, response.read()
                    expected = reference(data, discard)
                    assert actual == expected, (data.hex(), discard, actual, expected)
                    count += 1
            verify_packed(client, varint)
            client.close()
            client = None
            assert stop(server) == 0
            print(f'PASS: {count} independent wire comparisons')
        except BaseException:
            log.seek(0)
            sys.stderr.buffer.write(log.read())
            raise
        finally:
            if client:
                client.close()
            stop(server)


if __name__ == '__main__':
    main()
