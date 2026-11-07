#!/usr/bin/env python3
"""Sends the same requests to axum 0.8.9 and to roxum, and compares the status,
the body, and the headers that are part of the contract.

A difference is either listed in INTENDED with its reason, or a failure; so is a
listed difference that no longer appears, so the list stays true.

    tools/axum-contract/run.sh
"""
import gzip
import http.client
import os
import signal
import subprocess
import sys

JSON = {"content-type": "application/json"}
FORM = {"content-type": "application/x-www-form-urlencoded"}
BOUNDARY = "b0undary"
MULTIPART = {"content-type": f"multipart/form-data; boundary={BOUNDARY}"}
COMPARED_HEADERS = ("content-type", "content-encoding", "vary", "location", "x-layer", "x-nested")


def part(name, value):
    return f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n--{BOUNDARY}--\r\n'.encode()


# (method, path, headers, body)
CASES = [
    ("GET", "/text", {}, None),
    ("HEAD", "/text", {}, None),
    ("GET", "/text/", {}, None),
    ("POST", "/text", {}, None),
    ("OPTIONS", "/text", {}, None),
    ("GET", "/missing", {}, None),
    ("GET", "/json-reply", {}, None),
    # JSON: its media types, then bodies that do not fit.
    ("POST", "/json", JSON, b'{"name":"a"}'),
    ("POST", "/json", {"content-type": "application/json; charset=utf-8"}, b'{"name":"a"}'),
    ("POST", "/json", {"content-type": "application/problem+json"}, b'{"name":"a"}'),
    ("POST", "/json", {"content-type": "text/plain"}, b'{"name":"a"}'),
    ("POST", "/json", {}, b'{"name":"a"}'),
    ("POST", "/json", JSON, b"{"),
    ("POST", "/json", JSON, b'{"name":1}'),
    ("POST", "/json", JSON, b"{}"),
    ("POST", "/json", JSON, b""),
    # Query.
    ("GET", "/query?q=a%20b", {}, None),
    ("GET", "/query?q=a+b&page=2", {}, None),
    ("GET", "/query?q=a&other=1", {}, None),
    ("GET", "/query?page=2", {}, None),
    ("GET", "/query?q=a&page=x", {}, None),
    ("GET", "/query?q=a&q=b", {}, None),
    # Form.
    ("POST", "/form", FORM, b"name=a%20b"),
    ("POST", "/form", FORM, b"other=1"),
    ("POST", "/form", {"content-type": "text/plain"}, b"name=a"),
    ("POST", "/form", {}, b"name=a"),
    ("GET", "/form", {}, None),
    # Multipart.
    ("POST", "/upload", MULTIPART, part("name", "a")),
    ("POST", "/upload", MULTIPART, part("other", "a")),
    ("POST", "/upload", {"content-type": "multipart/form-data"}, b"x"),
    ("POST", "/upload", {"content-type": "text/plain"}, b"x"),
    # Paths: a type, encoded bytes, not UTF-8, a catch-all.
    ("GET", "/items/1", {}, None),
    ("GET", "/items/x", {}, None),
    ("GET", "/items/%31", {}, None),
    ("GET", "/items/", {}, None),
    ("GET", "/words/a%20b", {}, None),
    ("GET", "/words/a%2Fb", {}, None),
    ("GET", "/words/a+b", {}, None),
    ("GET", "/words/%FF", {}, None),
    ("GET", "/rest/a", {}, None),
    ("GET", "/rest/a/b/", {}, None),
    ("GET", "/rest/", {}, None),
    ("GET", "/rest", {}, None),
    # The body limit.
    ("POST", "/limited", {}, b"x" * 1023),
    ("POST", "/limited", {}, b"x" * 1024),
    ("POST", "/limited", {}, b"x" * 1025),
    # Status and redirects.
    ("GET", "/created", {}, None),
    ("GET", "/see-other", {}, None),
    ("GET", "/temporary", {}, None),
    ("GET", "/permanent", {}, None),
    # Methods: HEAD follows GET, 405 names what is there.
    ("GET", "/methods", {}, None),
    ("HEAD", "/methods", {}, None),
    ("DELETE", "/methods", {}, None),
    ("PUT", "/methods", {}, None),
    ("GET", "/delete-only", {}, None),
    # Layers: only over what was written above them.
    ("GET", "/before", {}, None),
    ("POST", "/before", {}, None),
    ("GET", "/refused", {}, None),
    # Nesting and fallbacks.
    ("GET", "/api/items/1", {}, None),
    ("POST", "/api/items/1", {}, None),
    ("GET", "/api/other", {}, None),
    ("GET", "/api", {}, None),
    ("GET", "/api/", {}, None),
    ("GET", "/plain/items/1", {}, None),
    ("GET", "/plain/other", {}, None),
    # Compression at its default threshold, and what turns it off.
    ("GET", "/sized/31", {"accept-encoding": "gzip"}, None),
    ("GET", "/sized/32", {"accept-encoding": "gzip"}, None),
    ("GET", "/sized/33", {"accept-encoding": "gzip"}, None),
    ("GET", "/sized/100", {"accept-encoding": "gzip;q=0"}, None),
    ("GET", "/sized/100", {}, None),
]

# The status of a refused request is the contract. Its body is words for a person,
# and each framework has its own.
REFUSALS = {400, 413, 415, 422}

# (method, path, content-type, body, field) -> why it differs.
JSON_MISMATCH = "Json.parse documents one InvalidJson for a type mismatch and a syntax error, so both are 400"
MULTIPART_MEDIA_TYPE = "the wrong media type is 415, as for Json and Form; axum's Multipart alone answers 400"
NESTED_SLASH = "/api/ is under the prefix, so the nested router's fallback answers; axum 0.8 matches only /api and /api/..."
ABOVE = "above_bytes means more than: at exactly the threshold roxum does not compress; tower-http's SizeAbove does"
INTENDED = {
    ("POST", "/json", "application/json", b'{"name":1}', "status"): JSON_MISMATCH,
    ("POST", "/json", "application/json", b"{}", "status"): JSON_MISMATCH,
    ("POST", "/upload", "multipart/form-data", b"x", "status"): MULTIPART_MEDIA_TYPE,
    ("POST", "/upload", "text/plain", b"x", "status"): MULTIPART_MEDIA_TYPE,
    ("GET", "/api/", "-", None, "body"): NESTED_SLASH,
    ("GET", "/sized/32", "-", None, "content-encoding"): ABOVE,
    ("GET", "/sized/32", "-", None, "vary"): ABOVE,
}


def exchange(port, method, path, headers, body):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    received = response.read()
    connection.close()
    if response.headers.get("content-encoding") == "gzip":
        received = gzip.decompress(received)
    answer = {"status": response.status, "body": received}
    for name in COMPARED_HEADERS:
        answer[name] = response.headers.get(name)
    # The same methods, however they are spelled.
    allow = response.headers.get("allow")
    answer["allow"] = sorted(method.strip() for method in allow.split(",")) if allow is not None else None
    return answer


def start(command):
    server = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    return server, int(server.stdout.readline())


def main(axum, roxum):
    axum_server, axum_port = start([axum])
    roxum_server, roxum_port = start([roxum])
    found = {}
    try:
        for method, path, headers, body in CASES:
            left = exchange(axum_port, method, path, headers, body)
            right = exchange(roxum_port, method, path, headers, body)
            refused = left["status"] in REFUSALS and right["status"] in REFUSALS
            for field in left:
                if refused and field in ("body", "content-type"):
                    continue
                if left[field] != right[field]:
                    media = headers.get("content-type", "-")
                    shown = f"{len(body)} bytes" if body and len(body) > 40 else body
                    found[(method, path, media, shown, field)] = (left[field], right[field])
    finally:
        # The process group: roxum's supervisor has a worker under it.
        os.killpg(axum_server.pid, signal.SIGKILL)
        os.killpg(roxum_server.pid, signal.SIGKILL)

    unexpected = {key: value for key, value in found.items() if key not in INTENDED}
    stale = [key for key in INTENDED if key not in found]
    for key, (left, right) in unexpected.items():
        print(f"DIFFERS {key}\n   axum:  {left!r}\n   roxum: {right!r}")
    for key in stale:
        print(f"NO LONGER DIFFERS {key}: {INTENDED[key]}")
    print(f"{len(CASES)} requests, {len(found)} differences, {len(found) - len(unexpected)} of them intended")
    if unexpected or stale:
        raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
