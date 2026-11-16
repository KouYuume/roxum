"""Runtime layout feasibility, not Protobuf encoding or decoder conformance."""
import http.client
import os
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import read_port, stop
from map_cases import verify_maps


def expected(path, depth, seed):
    # Independent closed forms for the chain and the comb-shaped tree.
    nodes = 2 * depth + 1 if path == '/tree' else depth + 1
    per_node_bytes = len(f'recursive payload {seed} 🐦'.encode()) + 3
    payload_sum = seed + 255
    total = nodes * (seed + payload_sum) + depth * (depth + 1) // 2
    original = f'{nodes},{total},{nodes * per_node_bytes}'
    replacement = f'1,{seed + depth + payload_sum},{per_node_bytes}'
    return f'{original};{replacement};{original}'.encode()


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

            verify_maps(call)

            # Signed extremes, neighbors of declared 0/1, and unknown values.
            for number in [-(1 << 31), -(1 << 31)+1, -1, 0, 1, 2, (1 << 31)-2, (1 << 31)-1]:
                original = f'{number}|present:{number}|0,{number},1,1|equal'
                changed = f'{number}|absent||equal'
                wanted = f'{original};{changed};{original}'.encode()
                assert call('/enum', number.to_bytes(4, 'little', signed=True)) == (200, wanted)
            for size in [0, 3, 5]:
                assert call('/enum', b'\0'*size) == (400, b'InputLength')
            for path in ['/node', '/mutual', '/tree']:
                # Empty edges, both mutual-recursion terminal types, and nearest
                # values on either side of the fixture's inclusive depth bound.
                for depth in [0, 1, 2, 63, 64, 65]:
                    # Byte extremes and decimal-width transitions vary heap text.
                    for seed in [0, 9, 10, 99, 100, 255]:
                        result = call(path, bytes([depth, seed]))
                        wanted = (200, expected(path, depth, seed)) if depth <= 64 else (400, b'DepthLimit')
                        assert result == wanted, (path, depth, seed, result, wanted)
                # Input length has a single accepted value: two bytes.
                for data in [b'\x01', b'\x01\x02\x03']:
                    assert call(path, data) == (400, b'InputLength')
                assert call(path, b'') == (400, b'InputLength')
            # Reuse one connection across request lifetimes with different deep,
            # shared values. Tracking allocators also check ownership on release.
            for index in range(32):
                for path in ['/node', '/mutual', '/tree']:
                    depth = 63 + index % 2
                    seed = index
                    assert call(path, bytes([depth, seed])) == (200, expected(path, depth, seed))
            assert call('/node', bytes([0, 0])) == (200, expected('/node', 0, 0))
            client.close()
            client = None
            assert stop(server) == 0
            if os.environ.get('ROXUM_CONTRACT_ALLOC') == '1':
                log.seek(0)
                diagnostics = log.read().decode(errors='replace')
                assert diagnostics.count('roxum-contract-request-ok') == count, diagnostics
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
    print(f'PASS Protobuf layout feasibility ({count} requests)')


if __name__ == '__main__':
    verify(str(pathlib.Path(sys.argv[1]).resolve()))
