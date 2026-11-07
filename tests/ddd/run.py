#!/usr/bin/env python3
"""One variant of the DDD example's check (tools/check.py builds the
executable): runs verify.py against a throwaway PostgreSQL of its own.

    run.py <arena|tracking> <executable>
"""
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "tests" / "support"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import postgres_server  # noqa: E402
import verify  # noqa: E402

def main(allocator, executable):
    os.chdir(root)
    with tempfile.TemporaryDirectory(prefix="roxum-ddd-") as temporary:
        temporary = pathlib.Path(temporary)
        os.chmod(temporary, 0o755)
        certificates = temporary / "certificates"
        certificates.mkdir()
        postgres_server.make_certificates(certificates)
        password_file = temporary / "database-password"
        password_file.write_text(postgres_server.APP_PASSWORD + "\n")
        server = postgres_server.start(certificates)
        try:
            verify.main(executable, server.port, password_file, allocator == "tracking")
        finally:
            server.stop()
    print(f"M9b-5 {allocator}: PASS", flush=True)


if __name__ == "__main__":
    main(*sys.argv[1:3])
