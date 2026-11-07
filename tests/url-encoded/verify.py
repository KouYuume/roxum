#!/usr/bin/env python3
"""URL-encoded contract against Python's independent percent/UTF-8 decoders.

All byte values cover lead-byte classes; constrained continuation boundaries
cover the nearest byte below, on, and above each UTF-8 permitted range.
"""
import http.client
import os
import pathlib
import random
import subprocess
import sys
import tempfile
from urllib.parse import unquote_to_bytes

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "support"))
from roxum_process import read_port, stop


def expected(raw):
    output = bytearray()
    for segment in raw.split(b"&"):
        if not segment:
            continue
        name, _, value = segment.partition(b"=")
        for component in (name, value):
            decoded = unquote_to_bytes(component.replace(b"+", b" ")).decode("utf-8", "replace").encode()
            output.extend(str(len(decoded)).encode() + b":" + decoded)
    return bytes(output)


cases = [b"", b"&&", b"a&a=&=x&=&a=x=y&&", b"a+b=%26%3d%2B+%20&%61+b=%2520",
         b"%=x&%2=x&%G0=x&%0g=x&%%41=x", b"q=%EF%BB%BF%E9%B5%AC%00", "q=鵬".encode()]
# Exhaustive single-byte domain, both raw and escaped, in names and values.
for byte in range(256):
    cases.extend([bytes([byte]) + b"=" + bytes([byte]), f"%{byte:02X}=%{byte:02x}".encode()])
# General and special first-continuation intervals, including outside values.
for lead, low, high, tail in [(0xC2, 0x80, 0xBF, b""), (0xE0, 0xA0, 0xBF, b"\x80"),
                             (0xED, 0x80, 0x9F, b"\x80"), (0xF0, 0x90, 0xBF, b"\x80\x80"),
                             (0xF4, 0x80, 0x8F, b"\x80\x80")]:
    for second in sorted({low - 1, low, low + 1, high - 1, high, high + 1}):
        cases.append(b"q=" + bytes([lead, second]) + tail)
# Truncation at each position and resumption on ASCII or a new valid sequence.
for sequence in [b"\xc2\xa2", b"\xe2\x82\xac", b"\xf0\x9f\x92\xa9"]:
    for cut in range(1, len(sequence)):
        for suffix in [b"", b"A", b"\xc2\xa2"]:
            cases.append(b"q=" + sequence[:cut] + suffix)
random_source = random.Random(2408)
for _ in range(100):
    cases.append(bytes(random_source.randrange(256) for _ in range(random_source.randrange(1, 128))))

requests = 0
with tempfile.TemporaryFile(mode="w+") as stderr:
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
    try:
        client = http.client.HTTPConnection("127.0.0.1", read_port(server), timeout=10)

        def check(path, raw, result):
            global requests
            requests += 1
            client.request("POST", path, raw)
            response = client.getresponse()
            actual = response.read()
            assert (response.status, actual) == (200, result), (path, raw, response.status, actual, result)

        for raw in cases:
            check("/decode", raw, expected(raw))
        # Inclusive byte limit 3 and field limit 2: below/on/above.
        for raw in [b"a=", b"a=x", b"a=x&"]:
            check("/bytes", raw, expected(raw) if len(raw) <= 3 else b"bytes")
        for raw in [b"a", b"a&a", b"a&a&a"]:
            check("/fields", raw, b"fields" if raw.count(b"&") == 2 else expected(raw))
        check("/fields", b"&&a&&a&&", expected(b"a&a"))
        check("/zero", b"", b"")
        check("/zero", b"&", b"bytes")
        check("/no-fields", b"&&", b"")
        check("/no-fields", b"=", b"fields")
        # Declared large-domain limits, independently of the focused tests.
        for length in [4095, 4096, 4097]:
            raw = b"x" * length
            check("/decode", raw, expected(raw) if length <= 4096 else b"bytes")
        for count in [255, 256, 257]:
            raw = b"&".join([b"x"] * count)
            check("/decode", raw, expected(raw) if count <= 256 else b"fields")
        client.close()
        print(f"PASS URL-encoded: {requests} requests, byte domain, UTF-8 boundaries, limits, keepalive")
    finally:
        assert stop(server) == 0
        stderr.seek(0)
        output = stderr.read()
        assert "CONTRACT" not in output and "crashed" not in output, output
        if os.environ.get("ROXUM_CONTRACT_ALLOC") == "1":
            assert output.count("roxum-contract-request-ok") == requests, output
