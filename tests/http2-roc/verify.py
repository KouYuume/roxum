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

    # Two suspended Roc invocations retain separate heaps while peers finish.
    delayed = b'detached body survives other request generations' * 4
    request(61, path='/sleep', payload=delayed)
    request(63, payload=b'while sleeping')
    flush()
    request(65, path='/sleep', payload=b'reset while sleeping' * 4)
    flush()
    # Closure pins the running lease until the suspended invocation cleans up.
    client.reset_stream(65)
    request(67, payload=b'after sleeping reset')
    flush()
    flush()  # An empty record explicitly resumes timer waits to completion.
    expected.update({61: (200, b'42|h2|' + delayed),
                     63: (200, b'42|h2|while sleeping'),
                     67: (200, b'42|h2|after sleeping reset')})
    # EOF disconnects before draining the last suspended invocation. Its owned
    # request remains valid, but its response must never be submitted.
    request(69, path='/sleep', payload=b'disconnect while sleeping' * 4)
    request(71, payload=b'before disconnect')
    flush()
    expected[71] = (200, b'42|h2|before disconnect')

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
    assert end_order.index(63) < end_order.index(61), end_order
    assert end_order.index(67) < end_order.index(61), end_order
    assert headers[53][':status'] == '404'
    assert headers[51]['content-length'] == str(len(b'42|h2|head'))
    for stream, (status, body) in expected.items():
        assert headers[stream][':status'] == str(status), (stream, headers[stream])
        assert bodies[stream] == body, (stream, bodies[stream], body)
    assert b'handled=31 rejected=4' in result.stderr, result.stderr
    assert result.stderr.count(b'detached-request') == 3, result.stderr
    assert result.stderr.count(b'resumed-request') == 6, result.stderr
    if allocator == 'tracking':
        assert result.stderr.count(b'roxum-contract-request-ok') == 35, result.stderr
    print(f'PASS real Roc HTTP/2 {allocator}/{backend}: model reuse, fragmented input, HEAD, errors, fiber waits, reset and cleanup')


if __name__ == '__main__':
    verify(*sys.argv[1:])
