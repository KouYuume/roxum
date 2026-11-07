"""File transfer over a local stand-in for SSM; never invokes aws or contacts a host."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import ssm_session


class LocalTransport:
    def __init__(self, fail_after=None):
        self.calls = []
        self.fail_after = fail_after

    def script(self, source):
        self.calls.append(source)
        if self.fail_after is not None and len(self.calls) > self.fail_after and "unlink" not in source:
            raise RuntimeError("transport failed")
        return subprocess.check_output(["python3", "-c", source], text=True)


class TransferTests(unittest.TestCase):
    def test_chunk_boundaries_round_trip(self):
        # Empty, one byte below, at, and above a chunk, and several chunks.
        chunk = ssm_session.CHUNK
        for size in (0, chunk - 1, chunk, chunk + 1, 3 * chunk + 5):
            with self.subTest(size=size), tempfile.TemporaryDirectory() as directory:
                data = os.urandom(size)
                local = Path(directory) / "local"
                local.write_bytes(data)
                remote = Path(directory) / "remote"
                transport = LocalTransport()
                sent = ssm_session.upload(transport, str(local), str(remote))
                self.assertEqual(remote.read_bytes(), data)
                self.assertEqual(sent["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(sum("b64decode" in call for call in transport.calls), -(-size // chunk))
                back = Path(directory) / "back"
                received = ssm_session.fetch(transport, str(remote), str(back))
                self.assertEqual(back.read_bytes(), data)
                self.assertEqual(received["sha256"], sent["sha256"])

    def test_existing_destinations_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            local = Path(directory) / "local"
            local.write_bytes(b"new")
            remote = Path(directory) / "remote"
            remote.write_bytes(b"old")
            with self.assertRaises(subprocess.CalledProcessError):
                ssm_session.upload(LocalTransport(), str(local), str(remote))
            self.assertEqual(remote.read_bytes(), b"old")
            self.assertEqual([p.name for p in Path(directory).iterdir() if "partial" in p.name], [])
            with self.assertRaises(FileExistsError):
                ssm_session.fetch(LocalTransport(), str(remote), str(local))
            self.assertEqual(local.read_bytes(), b"new")

    def test_a_failed_upload_leaves_no_partial_file(self):
        with tempfile.TemporaryDirectory() as directory:
            local = Path(directory) / "local"
            local.write_bytes(os.urandom(3 * ssm_session.CHUNK))
            remote = Path(directory) / "remote"
            with self.assertRaises(RuntimeError):
                ssm_session.upload(LocalTransport(fail_after=2), str(local), str(remote))
            self.assertFalse(remote.exists())
            self.assertEqual(list(Path(directory).iterdir()), [local])


if __name__ == "__main__":
    unittest.main()
