#!/usr/bin/env python3
"""roxum-rate-limit: limits from tags, counts across connections, a full counter,
and a window that ends, in one backend and allocator."""
import concurrent.futures
import http.client
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

HOUR = 3600


def get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", path)
    response = connection.getresponse()
    response.read()
    connection.close()
    return response.status, response.headers.get("retry-after")


def expect(port, path, *statuses):
    actual = [get(port, path)[0] for _ in statuses]
    if actual != list(statuses):
        raise RuntimeError(f"{path}: {actual}, expected {list(statuses)}")


def main(executable):
    server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        port = read_port(server)
        expect(port, "/free", *[200] * 10)

        # The limit, then 429 with the wait; 429s go on being counted.
        expect(port, "/limited", 200, 200, 200, 429, 429)
        status, retry_after = get(port, "/limited")
        if status != 429 or not 0 < int(retry_after) <= HOUR:
            raise RuntimeError(f"/limited: {status} retry-after {retry_after!r}")

        # Another key on the same counter counts apart.
        expect(port, "/other", 200, 429)

        # A route with two tags is checked by both: the first has room, the second
        # is already over.
        expect(port, "/two", 429)

        # Requests at once on any thread share the count.
        with concurrent.futures.ThreadPoolExecutor(16) as pool:
            statuses = list(pool.map(lambda _: get(port, "/full-reject?shared")[0], range(120)))
        if statuses.count(200) != 100 or statuses.count(429) != 20:
            raise RuntimeError(f"shared count: {statuses.count(200)} ok, {statuses.count(429)} refused")

        # The counter holds 2 keys, and `shared` is one. A new key takes the other,
        # then a third is treated as the route says, and is not recorded.
        expect(port, "/full-reject?second", 200)
        expect(port, "/full-reject?third", 429, 429)
        expect(port, "/full-allow?third", *[200] * 3)
        # A key already in goes on counting.
        expect(port, "/full-allow?second", 200)

        # Failures only: a right password does not count, two wrong ones lock.
        expect(port, "/login/right", 200, 200, 200)
        expect(port, "/login/wrong", 401, 401, 429)
        expect(port, "/login/right", 429)

        # A window that ends: over, then two windows later free again.
        expect(port, "/short", 200, 200, 429)
        time.sleep(4.2)
        expect(port, "/short", 200)
    finally:
        stop(server)


if __name__ == "__main__":
    main(sys.argv[1])
    print("roxum-rate-limit: ok")
