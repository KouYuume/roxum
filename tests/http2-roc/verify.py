"""Independent HTTP/2 encoding/decoding around actual Roc execution."""
import collections
import struct
import subprocess
import sys

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset


def verify(executable, allocator, backend):
    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
    records = []
    client.initiate_connection()

    def flush():
        data = client.data_to_send()
        records.append(struct.pack('!I', len(data)) + data)

    def request(stream, path='/echo', payload=b'', method='POST', end=True):
        client.send_headers(stream, [(':method', method), (':scheme', 'http'),
                                     (':authority', 'localhost'), (':path', path)],
                            end_stream=end and not payload)
        if payload:
            client.send_data(stream, payload, end_stream=end)

    flush()
    # A complete request is eligible for execution, but its reset in the same
    # input batch must cancel it before the fixture can invoke Roc.
    request(1, payload=b'cancelled')
    client.reset_stream(1)
    request(3, payload=b'first')
    flush()
    expected = {3: (200, b'42|h2|first')}
    # An unfinished body cannot hold up a ready peer; fragments reach Roc intact.
    request(5, payload=b'part-', end=False)
    request(7, payload=b'peer')
    flush()
    client.send_data(5, b'two', end_stream=True)
    flush()
    expected.update({5: (200, b'42|h2|part-two'), 7: (200, b'42|h2|peer')})
    # Repeated calls exceed slot capacity across completed request generations.
    for stream in range(9, 49, 2):
        payload = (f'request-{stream}-' * 4).encode()
        request(stream, payload=payload)
        flush()
        expected[stream] = (200, b'42|h2|' + payload)
    request(49, path='/reject')
    request(51, method='HEAD', payload=b'head')
    request(53, path='/missing')
    flush()
    expected.update({49: (422, b'rejected by Roc'), 51: (200, b'')})
    # Both pre-invocation and post-invocation failures release their request.
    request(55, method='TRACE')
    request(57, path='/invalid-response')
    request(59, payload=b'after errors')
    flush()
    expected[59] = (200, b'42|h2|after errors')

    result = subprocess.run([executable], input=b''.join(records), capture_output=True, timeout=60)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    bodies = collections.defaultdict(bytes)
    headers, ended, reset = {}, set(), set()
    end_order = []
    for event in client.receive_data(result.stdout):
        if isinstance(event, ConnectionTerminated):
            raise AssertionError(f'unexpected connection termination: {event}')
        if isinstance(event, ResponseReceived):
            headers[event.stream_id] = dict(event.headers)
        elif isinstance(event, DataReceived):
            bodies[event.stream_id] += event.data
        elif isinstance(event, StreamEnded):
            ended.add(event.stream_id)
            end_order.append(event.stream_id)
        elif isinstance(event, StreamReset):
            reset.add(event.stream_id)
    assert ended == set(expected) | {53}, (ended, reset)
    assert reset == {55, 57}, reset
    assert end_order.index(7) < end_order.index(5), end_order
    assert headers[53][':status'] == '404'
    assert headers[51]['content-length'] == str(len(b'42|h2|head'))
    for stream, (status, body) in expected.items():
        assert headers[stream][':status'] == str(status), (stream, headers[stream])
        assert bodies[stream] == body, (stream, bodies[stream], body)
    assert b'handled=27 rejected=2' in result.stderr, result.stderr
    if allocator == 'tracking':
        assert result.stderr.count(b'roxum-contract-request-ok') == 29, result.stderr
    print(f'PASS real Roc HTTP/2 {allocator}/{backend}: model reuse, fragmented input, HEAD, errors, reset and cleanup')


if __name__ == '__main__':
    verify(*sys.argv[1:])
