"""Exercise the file fixture over HTTP/2 with explicit flow control."""
import socket
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset
from h2.settings import SettingCodes


def verify(port, worker, public, check_http_features, transfer_sizes, open_files):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        client = H2Connection(config=H2Configuration(header_encoding="utf-8"))
        client.initiate_connection()
        sock.sendall(client.data_to_send())

        def send(path, headers=None, method="GET"):
            stream = client.get_next_available_stream_id()
            fields = [(":method", method), (":scheme", "http"), (":authority", "localhost"), (":path", path)]
            fields.extend((k.lower(), v) for k, v in (headers or {}).items())
            client.send_headers(stream, fields, end_stream=True)
            sock.sendall(client.data_to_send())
            return stream

        def receive():
            data = sock.recv(65536)
            if not data:
                raise RuntimeError("HTTP/2 connection closed during file response")
            return client.receive_data(data)

        def request(_port, path, headers=None, method="GET"):
            stream = send(path, headers, method)
            fields = {}
            body = bytearray()
            while True:
                events = receive()
                ended = False
                for event in events:
                    if getattr(event, "stream_id", None) != stream:
                        continue
                    if isinstance(event, ResponseReceived):
                        fields = dict(event.headers)
                    elif isinstance(event, DataReceived):
                        body.extend(event.data)
                        client.acknowledge_received_data(event.flow_controlled_length, stream)
                    elif isinstance(event, StreamReset):
                        raise RuntimeError(f"reset on {method} {path}: {event.error_code}")
                    elif isinstance(event, StreamEnded):
                        ended = True
                sock.sendall(client.data_to_send())
                if ended:
                    return int(fields[":status"]), fields, bytes(body)

        check_http_features(port, request)
        for size in transfer_sizes:
            status, headers, body = request(port, f"/files/boundary-{size}.bin")
            assert (status, headers["content-length"], body) == (
                200, str(size), (public / f"boundary-{size}.bin").read_bytes())
        status, headers, body = request(port, "/files/a.txt", method="HEAD")
        assert (status, headers["content-length"], body) == (200, "5", b"")

        baseline = open_files(worker)
        client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 1})
        blocked = send("/files/big.bin")
        while not any(isinstance(e, DataReceived) and e.stream_id == blocked and e.data for e in receive()):
            pass
        # The file owns the sole writer slot, but a finite peer can still finish.
        client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 16})
        assert request(port, "/quick")[::2] == (200, b"quick")
        assert request(port, "/files/a.txt")[0] == 503
        client.reset_stream(blocked)
        sock.sendall(client.data_to_send())

        deadline = time.monotonic() + 5
        while open_files(worker) > baseline or request(port, "/files/a.txt")[0] == 503:
            if time.monotonic() >= deadline:
                raise RuntimeError("reset file stream retained its descriptor or writer slot")
            time.sleep(0.02)
        assert request(port, "/files/a.txt")[::2] == (200, b"hello")

        # Shrink the file after DATA begins but before the next 64 KiB read.
        # The partial response must reset without completing or closing its peer.
        shrinking = public / "shrinking.bin"
        with shrinking.open("wb") as file:
            file.truncate(256 * 1024)
        stream = send("/files/shrinking.bin")
        while not any(isinstance(e, DataReceived) and e.stream_id == stream and e.data for e in receive()):
            pass
        with shrinking.open("wb"):
            pass
        client.increment_flow_control_window(256 * 1024, stream)
        sock.sendall(client.data_to_send())
        reset = False
        while not reset:
            for event in receive():
                if getattr(event, "stream_id", None) != stream:
                    continue
                if isinstance(event, DataReceived):
                    client.acknowledge_received_data(event.flow_controlled_length, stream)
                elif isinstance(event, StreamEnded):
                    raise RuntimeError("truncated file finished successfully")
                elif isinstance(event, StreamReset):
                    reset = True
            sock.sendall(client.data_to_send())
        assert request(port, "/quick")[::2] == (200, b"quick")
