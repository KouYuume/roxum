"""A publisher and an SSE subscriber share an external, live-only byte channel."""
from collections import defaultdict
from contextlib import closing
import http.client
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from roxum_process import read_port, stop


class BrokerRequest(socketserver.StreamRequestHandler):
    def handle(self):
        broker = self.server
        command = self.rfile.read(1)
        if command == b"S":
            with broker.changed:
                broker.subscribers.add(self.request)
                broker.changed.notify_all()
            # EOF is the unsubscribe signal, even when no events are published.
            try:
                trailing = self.rfile.read(1)
            except OSError as exc:
                trailing = exc
            with broker.changed:
                if trailing != b"":
                    broker.unsubscribe_error = f"expected subscriber EOF, received {trailing!r}"
                broker.subscribers.remove(self.request)
                broker.changed.notify_all()
        elif command == b"P":
            payload = self.rfile.read(1)
            if payload:
                with broker.changed:
                    for subscriber in broker.subscribers:
                        subscriber.sendall(payload)
                    self.wfile.write(bytes([len(broker.subscribers)]))


class Broker(socketserver.ThreadingTCPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), BrokerRequest)
        self.changed = threading.Condition()
        self.subscribers = set()
        self.unsubscribe_error = None

    def expect_subscribers(self, count):
        with self.changed:
            assert self.changed.wait_for(lambda: len(self.subscribers) == count, timeout=5), (
                count, len(self.subscribers))
            assert self.unsubscribe_error is None, self.unsubscribe_error


def event(payload):
    return b"data: " + payload + b"\n\n"


def verify_http1(port, broker):
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as publisher:
        def publish(payload, count):
            publisher.request("POST", "/publish", body=payload)
            with publisher.getresponse() as reply:
                assert reply.status == 200
                assert reply.read() == bytes([count])

        for payloads in ((b"A", b"B"), (b"C",)):
            with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as client:
                client.request("GET", "/events")
                with client.getresponse() as stream:
                    assert stream.status == 200 and stream.getheader("content-type") == "text/event-stream"
                    broker.expect_subscribers(1)
                    for payload in payloads:
                        publish(payload, 1)
                        assert stream.read(len(event(payload))) == event(payload)
            broker.expect_subscribers(0)
            publish(b"X", 0)


def verify_http2(port, broker):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        client = H2Connection(config=H2Configuration(header_encoding="utf-8"))
        client.initiate_connection()
        headers, bodies, ended = {}, defaultdict(bytes), set()

        def request(method, path, payload=None):
            sid = client.get_next_available_stream_id()
            client.send_headers(sid, [(":method", method), (":path", path), (":scheme", "http"),
                                      (":authority", "localhost")], end_stream=payload is None)
            if payload is not None:
                client.send_data(sid, payload, end_stream=True)
            sock.sendall(client.data_to_send())
            return sid

        def receive_until(done):
            while not done():
                wire = sock.recv(65536)
                assert wire, "connection closed with requests outstanding"
                for frame in client.receive_data(wire):
                    assert not isinstance(frame, (ConnectionTerminated, StreamReset)), frame
                    if isinstance(frame, ResponseReceived):
                        headers[frame.stream_id] = dict(frame.headers)
                    elif isinstance(frame, DataReceived):
                        bodies[frame.stream_id] += frame.data
                        client.acknowledge_received_data(frame.flow_controlled_length, frame.stream_id)
                    elif isinstance(frame, StreamEnded):
                        ended.add(frame.stream_id)
                sock.sendall(client.data_to_send())

        def publish(payload, count):
            sid = request("POST", "/publish", payload)
            receive_until(lambda: sid in ended)
            assert headers[sid][":status"] == "200" and bodies[sid] == bytes([count])

        for payloads in ((b"A", b"B"), (b"C",)):
            sub = request("GET", "/events")
            receive_until(lambda: sub in headers)
            assert headers[sub][":status"] == "200" and headers[sub]["content-type"] == "text/event-stream"
            broker.expect_subscribers(1)
            expected = b""
            for payload in payloads:
                publish(payload, 1)
                expected += event(payload)
                receive_until(lambda: len(bodies[sub]) >= len(expected))
                assert bodies[sub] == expected and sub not in ended
            client.reset_stream(sub)
            sock.sendall(client.data_to_send())
            broker.expect_subscribers(0)
            publish(b"X", 0)


def verify(executable, http2):
    with tempfile.TemporaryDirectory() as directory, Broker() as broker:
        config = Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f"broker_port = {broker.server_address[1]}\nhttp2 = {str(http2).lower()}\n")
        thread = threading.Thread(target=broker.serve_forever)
        thread.start()
        try:
            with subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                  start_new_session=True) as process:
                try:
                    port = read_port(process)
                    (verify_http2 if http2 else verify_http1)(port, broker)
                finally:
                    status = stop(process)
                assert status == 0, status
        finally:
            broker.shutdown()
            thread.join()


if __name__ == "__main__":
    executable = Path(sys.argv[1]).resolve()
    for http2 in (False, True):
        verify(executable, http2)
        print("PASS SSE publish, disconnect and resubscribe over", "HTTP/2" if http2 else "HTTP/1.1")
