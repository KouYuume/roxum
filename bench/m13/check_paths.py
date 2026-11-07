#!/usr/bin/env python3
"""Check path-validation boundaries against one built benchmark server."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path

import run as bench


def cases():
    # Valid route captures distinguish dots within names from dot segments.
    for value in ("a", "a.b", "..."):
        yield "ordinary capture", "/r99/items/" + value, 200, value.encode()
    for path in ("/.", "/..", "/r99/./items/a", "/r99/items/..",
                 "//plaintext", "/r99//items/a", "/plaintext//"):
        yield "structural path hazard", path, 400, None
    yield "query outside path", "/plaintext?value=//../", 200, b"Hello, World!"
    yield "empty query", "/plaintext?", 200, b"Hello, World!"
    # Nearest valid value below, at, and immediately above the host's 8 KiB limit.
    prefix = "/r99/items/"
    for length in (8191, 8192, 8193):
        value = "a" * (length - len(prefix))
        yield "target length boundary", prefix + value, 200 if length <= 8192 else 414, value.encode() if length <= 8192 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; preserve prior results")
    executable = args.executable.resolve()
    result = {"executable": str(executable), "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "cases": []}
    server = None
    try:
        server, port = bench.run_server(str(executable))
        for contract, path, status, body in cases():
            row = {"contract": contract, "path": path, "expected_status": status}
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            try:
                connection.request("GET", path)
                response = connection.getresponse()
                received = response.read()
                row.update(status=response.status, body_bytes=len(received),
                           body_sha256=hashlib.sha256(received).hexdigest(),
                           valid=response.status == status and (body is None or body == received))
            except Exception as error:
                row.update(valid=False, error=repr(error))
            finally:
                connection.close()
            result["cases"].append(row)
    except Exception as error:
        result["fatal_error"] = repr(error)
        raise
    finally:
        if server is not None:
            result["server_log"] = bench.stop_server(server)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    if not all(row["valid"] for row in result["cases"]):
        raise SystemExit("path validation failed; see retained results")
    print(f"{len(result['cases'])} path contracts passed")


if __name__ == "__main__":
    main()
