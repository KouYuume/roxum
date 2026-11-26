"""Exercise the file fixture over HTTP/2 with explicit flow control."""
import socket
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset
from h2.settings import SettingCodes


class FileClient:
    def __init__(self, sock):
        self.sock = sock
        self.client = H2Connection(config=H2Configuration(header_encoding="utf-8"))
        self.client.initiate_connection()
        self.sock.sendall(self.client.data_to_send())

    def send(self, path, headers=None, method="GET"):
        stream = self.client.get_next_available_stream_id()
        fields = [(":method", method), (":scheme", "http"), (":authority", "localhost"), (":path", path)]
        fields.extend((k.lower(), v) for k, v in (headers or {}).items())
        self.client.send_headers(stream, fields, end_stream=True)
        self.sock.sendall(self.client.data_to_send())
        return stream

    def receive(self):
        data = self.sock.recv(65536)
        if not data:
            raise RuntimeError("HTTP/2 connection closed during file response")
        return self.client.receive_data(data)

    def request(self, _port, path, headers=None, method="GET"):
        stream = self.send(path, headers, method)
        fields = {}
        body = bytearray()
        while True:
            events = self.receive()
            ended = False
            for event in events:
                if getattr(event, "stream_id", None) != stream:
                    continue
                if isinstance(event, ResponseReceived):
                    fields = dict(event.headers)
                elif isinstance(event, DataReceived):
                    body.extend(event.data)
                    self.client.acknowledge_received_data(event.flow_controlled_length, stream)
                elif isinstance(event, StreamReset):
                    raise RuntimeError(f"reset on {method} {path}: {event.error_code}")
                elif isinstance(event, StreamEnded):
                    ended = True
            self.sock.sendall(self.client.data_to_send())
            if ended:
                return int(fields[":status"]), fields, bytes(body)


def verify(port, public, check_http_features, transfer_sizes):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        peer = FileClient(sock)
        check_http_features(port, peer.request)
        for size in transfer_sizes:
            status, headers, body = peer.request(port, f"/files/boundary-{size}.bin")
            assert (status, headers["content-length"], body) == (
                200, str(size), (public / f"boundary-{size}.bin").read_bytes())
        status, headers, body = peer.request(port, "/files/a.txt", method="HEAD")
        assert (status, headers["content-length"], body) == (200, "5", b"")

        # Shrink the file after DATA begins but before the next 64 KiB read.
        # The partial response must reset without completing or closing its peer.
        shrinking = public / "shrinking.bin"
        with shrinking.open("wb") as file:
            file.truncate(256 * 1024)
        peer.client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 16})
        stream = peer.send("/files/shrinking.bin")
        while not any(isinstance(e, DataReceived) and e.stream_id == stream and e.data for e in peer.receive()):
            pass
        with shrinking.open("wb"):
            pass
        peer.client.increment_flow_control_window(256 * 1024, stream)
        sock.sendall(peer.client.data_to_send())
        reset = False
        while not reset:
            for event in peer.receive():
                if getattr(event, "stream_id", None) != stream:
                    continue
                if isinstance(event, DataReceived):
                    peer.client.acknowledge_received_data(event.flow_controlled_length, stream)
                elif isinstance(event, StreamEnded):
                    raise RuntimeError("truncated file finished successfully")
                elif isinstance(event, StreamReset):
                    reset = True
            sock.sendall(peer.client.data_to_send())
        assert peer.request(port, "/quick")[::2] == (200, b"quick")


def verify_quota(port, worker, open_files):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        peer = FileClient(sock)
        # Establish the connection before counting the worker's descriptors.
        assert peer.request(port, "/quick")[::2] == (200, b"quick")
        baseline = open_files(worker)
        peer.client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 1})
        blocked = peer.send("/files/big.bin")
        while not any(isinstance(e, DataReceived) and e.stream_id == blocked and e.data for e in peer.receive()):
            pass
        # The file owns the sole writer slot, but a finite peer can still finish.
        peer.client.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 16})
        assert peer.request(port, "/quick")[::2] == (200, b"quick")
        assert peer.request(port, "/files/a.txt")[0] == 503
        peer.client.reset_stream(blocked)
        sock.sendall(peer.client.data_to_send())

        deadline = time.monotonic() + 5
        while True:
            status, _, body = peer.request(port, "/files/a.txt")
            if status != 503:
                assert (status, body) == (200, b"hello")
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("reset file stream retained its writer slot")
            time.sleep(0.02)
        while open_files(worker) > baseline:
            if time.monotonic() >= deadline:
                raise RuntimeError("reset file stream retained its descriptor")
            time.sleep(0.02)
