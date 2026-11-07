#!/usr/bin/env python3
"""One variant of the roxum-postgres check (tools/check.py builds the
executables): runs verify.py against a throwaway PostgreSQL of its own, then
the protocol test against a fake server.

    run.py <arena|tracking> <example executable> <protocol executable>
"""
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / "tests" / "support"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(root / "integrations" / "roxum-postgres" / "tests"))
import postgres_server  # noqa: E402
import verify  # noqa: E402
import protocol  # noqa: E402

def main(allocator, executable, protocol_executable):
    os.chdir(root)
    with tempfile.TemporaryDirectory(prefix="roxum-postgres-") as temporary:
        temporary = pathlib.Path(temporary)
        os.chmod(temporary, 0o755)
        certificates = temporary / "certificates"
        certificates.mkdir()
        postgres_server.make_certificates(certificates)
        server = postgres_server.start(certificates)
        try:
            verify.main(executable, server.port, certificates, allocator == "tracking")
        finally:
            server.stop()
    protocol.main(pathlib.Path(protocol_executable))
    print(f"roxum-postgres {allocator}: PASS", flush=True)


if __name__ == "__main__":
    main(*sys.argv[1:4])
