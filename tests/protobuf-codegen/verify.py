"""Official Python Protobuf ↔ generated Roc scalar codecs, with separate value views."""
import http.client
import pathlib
import random
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'zig-out/protobuf-codegen'), str(ROOT / 'tests/support')]
import scalar_pb2 as reference
import catalog_pb2 as catalog
from roxum_process import read_port, stop
from scalar_cases import verify_scalars
from optional_cases import verify_optional
from identity_cases import verify_identities


def varint(number):
    data = bytearray()
    while number > 127:
        data.append((number & 127) | 128)
        number >>= 7
    data.append(number)
    return bytes(data)


def payload(data):
    return varint(536870911 * 8 + 2) + varint(len(data)) + data


def valid_cases():
    yield b''
    # Default omission, numeric widths, and varint width transitions.
    for shift in range(7, 64, 7):
        for value in [(1 << shift) - 1, 1 << shift, (1 << shift) + 1]:
            yield reference.Packet(count=value).SerializeToString()
    for value in [0, 1, (1 << 32) - 2, (1 << 32) - 1]:
        yield reference.Packet(code=value).SerializeToString()
    for value in [0, 1, (1 << 64) - 2, (1 << 64) - 1]:
        yield reference.Packet(count=value, stamp=value).SerializeToString()
    # Duplicate singular values overwrite, including replacement with a default.
    yield b'\x08\x01\x08\x00'
    yield payload(b'old') + payload(b'new')
    yield payload(b'old') + payload(b'')
    yield reference.Packet(code=1, stamp=2).SerializeToString() + reference.Packet(code=3, stamp=4).SerializeToString()
    # Legal overlong varints, reordered fields, unknown values/groups, wrong wire kinds.
    yield b'\x08\x81\x00'
    yield reference.Packet(stamp=9).SerializeToString() + b'\x08\x05'
    yield b'\x10\x03\x13\x08\x02\x14\x08\x07'
    yield b'\x0a\x02ab\x08\x04'
    yield b'\x78\x01\x82\x01\x00' + varint(536870911 * 8) + b'\x01'
    for size in [0, 1, 255, 256]:
        yield payload(bytes(range(256))[:size])
    rng = random.Random(731)
    for _ in range(60):
        yield reference.Packet(count=rng.getrandbits(64), code=rng.getrandbits(32),
                               stamp=rng.getrandbits(64),
                               payload=bytes(rng.randrange(256) for _ in range(rng.randrange(30)))).SerializeToString()


def verify(executable):
    with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as log:
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                  stderr=log, text=True, start_new_session=True)
        client = None
        count = 0
        try:
            client = http.client.HTTPConnection('127.0.0.1', read_port(server), timeout=10)

            def call(path, data):
                nonlocal count
                count += 1
                client.request('POST', path, data)
                response = client.getresponse()
                return response.status, response.read()

            def valid(data):
                expected = reference.Packet.FromString(data)
                status, encoded = call('/copy', data)
                assert status == 200, (data.hex(), status, encoded)
                actual = reference.Packet.FromString(encoded)
                for field in ['count', 'code', 'stamp', 'payload']:
                    assert getattr(actual, field) == getattr(expected, field), (field, data.hex(), actual, expected)
                # Inspect the decoded record directly: symmetric encoder/decoder mistakes cannot cancel.
                view = f'{expected.count},{expected.code},{expected.stamp},{len(expected.payload)}'.encode()
                assert call('/view', data) == (200, view)

            # Python's pure runtime keys known-field dispatch by raw tag bytes.
            # Keep this accepted non-minimal tag as an explicit contract test.
            nonminimal = b'\x88\x00\x81\x00'
            assert reference.Packet.FromString(nonminimal).count == 0
            assert call('/copy', nonminimal) == (200, b'\x08\x01')
            assert call('/view', nonminimal) == (200, b'1,0,0,0')
            verify_scalars(call, reference)
            verify_optional(call, reference)
            verify_identities(call, reference, catalog)
            for data in valid_cases():
                valid(data)
            status, encoded = call('/construct', b'')
            assert status == 200
            assert reference.Packet.FromString(encoded) == reference.Packet(
                count=(1 << 64) - 1, code=(1 << 32) - 1, stamp=1 << 63, payload=b'\0\x7f\x80\xff')
            assert call('/defaults', b'') == (200, b'')
            assert call('/copy', b'\x08\0' + payload(b'')) == (200, b'')
            assert call('/empty', reference.Packet(count=5).SerializeToString()) == (200, b'')

            def rejected(data, error, path='/copy'):
                assert call(path, data) == (400, error.encode()), (data.hex(), error)

            for data, error in [(b'\x00', 'InvalidTag'), (b'\x0e', 'InvalidWireType'),
                                (b'\x08' + b'\xff' * 9 + b'\x02', 'VarintOverflow'),
                                (b'\x13\x1c', 'MismatchedGroup'), (b'\x14', 'UnexpectedEndGroup')]:
                rejected(data, error)
            for data in [b'\x08\x80\x01', reference.Packet(code=1).SerializeToString(),
                         reference.Packet(stamp=1).SerializeToString(), payload(b'abc')]:
                # Every truncation after the complete tag must fail, not become a default value.
                tag_size = 5 if data.startswith(b'\xfa') else (2 if data[0] & 128 else 1)
                for length in range(tag_size, len(data)):
                    rejected(data[:length], 'Truncated')
            # Closest values on both sides of each configured budget.
            for size in [255, 256]:
                valid(payload(b'x' * size))
            rejected(payload(b'x' * 257), 'FieldLimit')
            for total in [511, 512]:
                valid(payload(b'x' * 256) + payload(b'y' * 255) + payload(b'z' * (total - 511)))
            rejected(payload(b'x' * 256) + payload(b'y' * 256) + payload(b'z'), 'MaterializationLimit')
            for tags in [127, 128]:
                valid(b'\x08\x01' * tags)
            rejected(b'\x08\x01' * 129, 'TagLimit')
            for depth in [7, 8]:
                valid(b'\x13' * depth + b'\x14' * depth)
            rejected(b'\x13' * 9 + b'\x14' * 9, 'DepthLimit')
            # Unknown length fields consume input but do not materialize bytes.
            prefix = (b'\x12\x80\x02' + b'x' * 256) * 15
            for total in [4095, 4096, 4097]:
                size = total - len(prefix) - 3
                data = prefix + b'\x12' + varint(size) + b'x' * size
                assert len(data) == total
                if total <= 4096:
                    valid(data)
                else:
                    rejected(data, 'InputLimit')
            for encoded_size in [15, 16, 17]:
                data = payload(b'x' * (encoded_size - 6))
                assert len(data) == encoded_size
                if encoded_size <= 16:
                    assert call('/limits', data) == (200, data)
                else:
                    rejected(data, 'OutputLimit', '/limits')
            # Error paths leave the host and subsequent codecs usable.
            valid(reference.Packet(count=42).SerializeToString())
            client.close()
            client = None
            assert stop(server) == 0
        except BaseException:
            stop(server)
            log.seek(0)
            print(log.read().decode(errors='replace'), file=sys.stderr)
            raise
        finally:
            if client:
                client.close()
            stop(server)
            server.stdout.close()
    print(f'PASS generated scalar Protobuf interoperability ({count} requests)')


if __name__ == '__main__':
    verify(str(pathlib.Path(sys.argv[1]).resolve()))
