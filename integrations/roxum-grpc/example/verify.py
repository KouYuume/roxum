"""Start the example and run its independent client against the printed endpoint."""
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tests/support'))
from roxum_process import read_port, stop
from client import verify


def main():
    process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(process)
        verify(f'127.0.0.1:{port}', Path(__file__).resolve().parents[3] / 'zig-out/grpc-example')
    finally:
        status = stop(process)
        process.stdout.close()
    assert status == 0


if __name__ == '__main__':
    main()
