#!/usr/bin/env python3
"""SSM transport for linux_server.py. Invoking this CLI executes commands on EC2."""
import argparse
import base64
import gzip
import hashlib
import json
import re
import shlex
import subprocess
import sys
import time
import uuid

CHUNK = 12000


class SSM:
    def __init__(self, profile, region, instance):
        self.prefix = ["aws", "--profile", profile, "--region", region,
                       "--no-cli-pager", "--output", "json", "ssm"]
        self.instance = instance
        self.command_ids = []

    def api(self, *args):
        result = subprocess.run([*self.prefix, *args], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)

    def script(self, source):
        shell = "python3 -c " + shlex.quote(source)
        response = self.api("send-command", "--instance-ids", self.instance,
                            "--document-name", "AWS-RunShellScript", "--timeout-seconds", "30",
                            "--parameters", json.dumps({"commands": [shell], "executionTimeout": ["50"]}))
        command_id = response["Command"]["CommandId"]
        self.command_ids.append(command_id)
        print(f"SSM command: {command_id}", file=sys.stderr, flush=True)
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            try:
                result = self.api("get-command-invocation", "--command-id", command_id,
                                  "--instance-id", self.instance)
            except RuntimeError as error:
                if "InvocationDoesNotExist" not in str(error):
                    raise
                time.sleep(1)
                continue
            if result["Status"] == "Success":
                if result["ResponseCode"] != 0:
                    raise RuntimeError(f"SSM returned nonzero response: {result}")
                return result["StandardOutputContent"]
            if result["Status"] not in ("Pending", "InProgress", "Delayed"):
                raise RuntimeError(f"SSM execution failed: {result}")
            time.sleep(1)
        self.api("cancel-command", "--command-id", command_id, "--instance-ids", self.instance)
        raise TimeoutError(f"SSM command timed out: {command_id}")


def transfer(transport, controller, action, config=None):
    argv = ["python3", controller, action] + ([config] if config is not None else [])
    artifact = "/tmp/roxum-bench-ssm-" + uuid.uuid4().hex
    source = f'''import gzip, hashlib, json, os, subprocess
result = subprocess.run({argv!r}, capture_output=True, text=True, timeout=45)
data = gzip.compress(json.dumps({{"stdout": result.stdout, "stderr": result.stderr, "code": result.returncode}}).encode())
fd = os.open({artifact!r}, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as stream:
    stream.write(data)
print(json.dumps({{"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}))
'''
    try:
        metadata = json.loads(transport.script(source))
        size = metadata["size"]
        if type(size) is not int or not 0 < size <= 4 * 1024 * 1024:
            raise ValueError("invalid or excessive controller output size")
        chunks = []
        for offset in range(0, size, CHUNK):
            encoded = transport.script(
                f"import base64; f=open({artifact!r},'rb'); f.seek({offset}); "
                f"print(base64.b64encode(f.read({CHUNK})).decode())")
            chunks.append(base64.b64decode(encoded.strip(), validate=True))
        data = b"".join(chunks)
        if len(data) != size or hashlib.sha256(data).hexdigest() != metadata["sha256"]:
            raise ValueError("SSM output was truncated or corrupted")
        envelope = json.loads(gzip.decompress(data))
        if envelope["stderr"]:
            print(envelope["stderr"], file=sys.stderr)
        if envelope["code"] != 0:
            raise RuntimeError(f"controller failed ({envelope['code']}): {envelope['stdout']}")
        return json.loads(envelope["stdout"])
    finally:
        # Unique per-call artifact; never delete a shared path or another trial's output.
        primary_error = sys.exc_info()[0] is not None
        try:
            transport.script(f"import pathlib; pathlib.Path({artifact!r}).unlink(missing_ok=True)")
        except Exception as error:
            if not primary_error:
                raise
            print(f"SSM artifact cleanup failed: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--instance", required=True)
    parser.add_argument("--controller", default="/opt/roxum/bench/m13/linux_server.py")
    parser.add_argument("action", choices=["start", "snapshot", "stop"])
    parser.add_argument("config", nargs="?")
    args = parser.parse_args()
    if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", args.instance):
        parser.error("instance must be one explicit EC2 instance ID")
    if (args.action == "start") != (args.config is not None):
        parser.error("only start requires a server config path")
    transport = SSM(args.profile, args.region, args.instance)
    print(json.dumps(transfer(transport, args.controller, args.action, args.config)))


if __name__ == "__main__":
    main()
