#!/usr/bin/env python3
"""Integration check of the common startup contract for all supplied binaries."""
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

import run as bench


def check(executable):
    # Missing/default, exact enabled marker, and immediately shorter/longer markers.
    for content in (None, b"enabled\n", b"enabled", b"enabled\n\n"):
        accepted = content in (None, b"enabled\n")
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile(mode="w+") as log:
            if content is not None:
                (Path(directory) / "benchmark-remote").write_bytes(content)
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=log, text=True, start_new_session=True)
            try:
                if accepted:
                    with selectors.DefaultSelector() as selector:
                        selector.register(process.stdout, selectors.EVENT_READ)
                        if not selector.select(20):
                            raise TimeoutError("no server port")
                    port = int(process.stdout.readline())
                    if content is not None:
                        assert port == 8080, port
                    for _, method, path, _, body in bench.SCENARIOS:
                        bench.validate_response(port, method, path, body)
                else:
                    assert process.wait(timeout=20) != 0, "invalid marker was accepted"
            finally:
                bench.stop_server(process)
                process.stdout.close()
        print(f"{Path(executable).name}: marker={content!r} passed", flush=True)


if __name__ == "__main__":
    for executable in sys.argv[1:]:
        check(str(Path(executable).resolve()))
