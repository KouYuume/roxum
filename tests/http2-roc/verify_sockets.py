"""Real outbound TCP readiness and cancellation through HTTP/2 request fibers."""
import collections
import queue
import socket
import struct
import subprocess
import sys
import tempfile
import threading

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset


def verify(executable, allocator, backend):
    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
    diagnostics = []
    lines = queue.Queue()
    with socket.socket() as listener, tempfile.TemporaryFile() as output:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(10)
        port = str(listener.getsockname()[1]).encode()
        process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=output, stderr=subprocess.PIPE)

        def collect_stderr():
            for line in process.stderr:
                diagnostics.append(line)
                lines.put(line)
            lines.put(None)

        reader = threading.Thread(target=collect_stderr, daemon=True)
        reader.start()

        def batch(drain=False):
            data = b'' if drain else client.data_to_send()
            assert drain or data, 'use an explicit drain for an empty batch'
            process.stdin.write(struct.pack('!I', len(data)) + data)
            process.stdin.flush()
            while True:
                line = lines.get(timeout=10)
                assert line is not None, b''.join(diagnostics).decode(errors='replace')
                if line == b'batch-complete\n':
                    return

        def request(stream, path, body=b''):
            client.send_headers(stream, [(':method', 'POST'), (':scheme', 'http'),
                                         (':authority', 'localhost'), (':path', path)],
                                end_stream=not body)
            if body:
                client.send_data(stream, body, end_stream=True)

        def waiting_connection(stream, path, peer):
            request(stream, path, port)
            request(peer, '/echo', b'peer')
            batch()
            connection, _ = listener.accept()
            connection.settimeout(10)
            try:
                # Acceptance proves connect readiness. A nonempty batch polls it
                # without draining the deliberately unanswered read.
                client.ping(struct.pack('!Q', stream))
                batch()
                assert f'socket-read-wait stream={stream}\n'.encode() in diagnostics, diagnostics
                return connection
            except BaseException:
                connection.close()
                raise

        try:
            client.initiate_connection()
            batch()
            # Send only after registration: readiness cannot be hidden by a
            # successful immediate read or by a timing-dependent server delay.
            with waiting_connection(1, '/tcp', 3) as connection:
                connection.sendall(b'A')
                batch(drain=True)
                assert connection.recv(1) == b'', 'normal discard did not close TCP'

            with waiting_connection(5, '/tcp-cancel', 7) as connection:
                request(9, '/permit')
                batch()
                client.reset_stream(5)
                request(11, '/permit', b'after reset')
                batch()
                assert connection.recv(1) == b'', 'reset did not close borrowed TCP'

            # Reuse freed request/wait slots after cancellation, then cancel a
            # fresh read on input EOF. Every upstream remains silent until told.
            with waiting_connection(13, '/tcp', 15) as connection:
                connection.sendall(b'B')
                batch(drain=True)
                assert connection.recv(1) == b''
            with waiting_connection(17, '/tcp-cancel', 19) as connection:
                process.stdin.close()
                assert process.wait(timeout=10) == 0, diagnostics
                assert connection.recv(1) == b'', 'disconnect did not close borrowed TCP'
            reader.join(timeout=10)
            assert not reader.is_alive()
            output.seek(0)
            wire = output.read()
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            reader.join(timeout=10)
            if not process.stdin.closed:
                process.stdin.close()
            process.stderr.close()

    expected = {1: b'A', 3: b'42|h2|peer', 7: b'42|h2|peer', 9: b'busy',
                11: b'42|h2|after reset', 13: b'B', 15: b'42|h2|peer', 19: b'42|h2|peer'}
    bodies = collections.defaultdict(bytes)
    headers, ended = {}, []
    for event in client.receive_data(wire):
        assert not isinstance(event, (ConnectionTerminated, StreamReset)), event
        if isinstance(event, ResponseReceived):
            headers[event.stream_id] = dict(event.headers)
        elif isinstance(event, DataReceived):
            bodies[event.stream_id] += event.data
        elif isinstance(event, StreamEnded):
            ended.append(event.stream_id)
    assert set(ended) == set(expected), ended
    assert set(headers) == set(expected), headers
    for stream, body in expected.items():
        assert headers[stream][':status'] == ('429' if stream == 9 else '200'), headers
        assert bodies[stream] == body, (stream, bodies[stream])
    assert ended.index(3) < ended.index(1), ended
    assert ended.index(15) < ended.index(13), ended
    log = b''.join(diagnostics)
    assert b'handled=8 rejected=0' in log, log
    assert log.count(b'detached-request') == 4, log
    assert log.count(b'cancelled-request') == 2, log
    assert log.count(b'socket-read-wait') == 4, log
    assert log.count(b'socket-ready') >= 2, log
    assert log.count(b'registered-wait') == log.count(b'collected-wait'), log
    assert log.count(b'resumed-request') == log.count(b'collected-wait'), log
    if allocator == 'tracking':
        assert log.count(b'roxum-contract-request-ok') == 8, log
    print(f'PASS real Roc HTTP/2 TCP {allocator}/{backend}: readiness, peer progress, reset/disconnect cleanup, slot reuse')


if __name__ == '__main__':
    verify(*sys.argv[1:])
