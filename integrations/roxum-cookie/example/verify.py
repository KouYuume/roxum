#!/usr/bin/env python3
"""roxum-cookie: Set-Cookie lines, reading, and signed values with key rotation,
in one backend and allocator."""
import hashlib
import hmac
import http.client
import os
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

KEY = "current-key-7f3a"
OLD_KEY = "previous-key-91bc"
OTHER_KEY = "unknown-key-0000"


def signed(key, name, value):
    message = b"roxum-cookie-v1\0" + f"{name}={value}".encode()
    return hmac.new(key.encode(), message, hashlib.sha256).hexdigest() + "." + value


# (path, Cookie field or None, status, body or None, Set-Cookie lines)
CASES = [
    ("/set", None, 200, b"ok", ["theme=dark; Path=/; SameSite=Lax; Secure; HttpOnly"]),
    ("/set-all", None, 200, b"ok", ["a=b; Path=/app; Domain=example.com; Max-Age=3600; SameSite=Strict"]),
    ("/set-encoded", None, 200, b"ok", ["note=a%20b%3B%C3%A9%25; Path=/; SameSite=Lax; Secure; HttpOnly"]),
    # Two cookies are two fields.
    ("/set-two", None, 200, b"ok", ["a=1; Path=/; SameSite=Lax; Secure; HttpOnly", "b=2; Path=/; SameSite=Lax; Secure; HttpOnly"]),
    # Without Secure, so that it also works over plain HTTP; a prefixed name needs it.
    ("/remove", None, 200, b"ok", ["theme=; Path=/; Max-Age=0"]),
    ("/remove-host", None, 200, b"ok", ["__Host-a=; Path=/; Max-Age=0; Secure"]),
    ("/refused", None, 200, b"name,path,path,domain,large,refused,refused,refused", []),
    # Reading: the value, a name that differs in case, no field, and an escape.
    ("/get", "theme=dark", 200, b"dark", []),
    ("/get", "a=1; theme=dark; b=2", 200, b"dark", []),
    ("/get", "Theme=dark", 404, None, []),
    ("/get", None, 404, None, []),
    ("/get", "theme=a%20b%3B%C3%A9%25", 200, "a b;é%".encode(), []),
    # Typed: the types choose; a cookie may be left out; a required one and a
    # value that does not fit answer 400; an unknown name is ignored; the first of
    # a repeated name counts.
    ("/typed", "count=3; theme=dark", 200, b"3 dark", []),
    ("/typed", "count=3", 200, b"3 none", []),
    ("/typed", "other=1; count=4", 200, b"4 none", []),
    ("/typed", "count=5; count=6", 200, b"5 none", []),
    ("/typed", "theme=dark", 400, None, []),
    ("/typed", "count=x", 400, None, []),
    # A `+` and a `&` in a value are themselves.
    ("/typed", "count=1; theme=a+b%26c", 200, b"1 a+b&c", []),
    # Signed: the current key, the previous key.
    ("/sign", None, 200, b"ok", [f"user={signed(KEY, 'user', '42')}; Path=/; SameSite=Lax; Secure; HttpOnly"]),
    ("/verified", f"user={signed(KEY, 'user', '42')}", 200, b"42", []),
    ("/verified", f"user={signed(OLD_KEY, 'user', '42')}", 200, b"42", []),
    # Refused: no cookie; an unknown key; a changed value; a signature made for
    # another name; a changed signature; no signature; a short one.
    ("/verified", None, 404, None, []),
    ("/verified", f"user={signed(OTHER_KEY, 'user', '42')}", 401, None, []),
    ("/verified", f"user={signed(KEY, 'user', '42')[:-1]}7", 401, None, []),
    ("/verified", f"user={signed(KEY, 'admin', '42')}", 401, None, []),
    ("/verified", f"user=0{signed(KEY, 'user', '42')[1:]}", 401, None, []),
    ("/verified", "user=42", 401, None, []),
    ("/verified", "user=ab.42", 401, None, []),
    # A forged cookie sent first does not hide a good one.
    ("/verified", f"user=bad; user={signed(KEY, 'user', '42')}", 200, b"42", []),
]


def main(executable):
    environment = {**os.environ, "ROXUM_COOKIE_KEY": KEY, "ROXUM_COOKIE_OLD_KEY": OLD_KEY}
    errors = tempfile.TemporaryFile("w+")
    server = subprocess.Popen([executable], env=environment, stdout=subprocess.PIPE, stderr=errors, text=True, start_new_session=True)
    try:
        port = read_port(server)
        # Repeated, because a wrong free shows only on some threads (C-18).
        for path, cookie, status, body, lines in CASES * 10:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            connection.request("GET", path, headers={"Cookie": cookie} if cookie is not None else {})
            try:
                response = connection.getresponse()
            except http.client.HTTPException as error:
                errors.seek(0)
                raise RuntimeError(f"{path} {cookie!r}: {error!r}; server stderr:\n{errors.read()}") from error
            actual = response.read()
            connection.close()
            set_cookie = response.headers.get_all("set-cookie") or []
            if response.status != status or (body is not None and actual != body) or set_cookie != lines:
                raise RuntimeError(f"{path} {cookie!r}: {response.status} {actual!r} {set_cookie!r}")
        # Two Cookie fields read as one list.
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        connection.putrequest("GET", "/get")
        connection.putheader("Cookie", "a=1")
        connection.putheader("Cookie", "theme=second")
        connection.endheaders()
        response = connection.getresponse()
        if response.read() != b"second":
            raise RuntimeError("the second Cookie field was not read")
        connection.close()
    finally:
        stop(server)


if __name__ == "__main__":
    main(sys.argv[1])
    print("roxum-cookie: ok")
