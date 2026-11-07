#!/usr/bin/env python3
"""Moves files to and from a benchmark host and runs long scripts on it, over SSM.

Usage: ssm_session.py --profile P --instance I upload LOCAL REMOTE
       ssm_session.py --profile P --instance I fetch REMOTE LOCAL
       ssm_session.py --profile P --instance I run SCRIPT [--timeout SECONDS]

Invoking this CLI executes commands on EC2. Files travel in base64 chunks
through SendCommand and GetCommandInvocation, so no S3 bucket or SSH is needed.
An upload is written to a temporary path, checked against its SHA-256, and
only then renamed to REMOTE, which must not exist. A fetch is checked the same
way and never overwrites LOCAL. `run` waits for a script and prints its exit
status and the end of its output; a script that keeps a full log on the host
can be fetched afterwards.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ssm_control import SSM

# SendCommand parameters and GetCommandInvocation output both have small
# limits; a chunk of this size stays well inside them once base64-encoded.
CHUNK = 12000


def upload(transport, local, remote):
    data = Path(local).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    partial = f"{remote}.partial-{uuid.uuid4().hex}"
    transport.script(f"import os; os.close(os.open({partial!r}, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))")
    try:
        for offset in range(0, len(data), CHUNK):
            encoded = base64.b64encode(data[offset:offset + CHUNK]).decode()
            transport.script(
                "import base64\n"
                f"f = open({partial!r}, 'r+b'); f.seek(0, 2)\n"
                f"assert f.tell() == {offset}, 'upload chunks out of order'\n"
                f"f.write(base64.b64decode({encoded!r}, validate=True)); f.close()")
        transport.script(
            "import hashlib, os\n"
            f"data = open({partial!r}, 'rb').read()\n"
            f"assert len(data) == {len(data)} and hashlib.sha256(data).hexdigest() == {digest!r}, 'upload corrupted'\n"
            f"assert not os.path.exists({remote!r}), 'destination exists'\n"
            f"os.rename({partial!r}, {remote!r})")
    except BaseException:
        try:
            transport.script(f"import pathlib; pathlib.Path({partial!r}).unlink(missing_ok=True)")
        except Exception as error:
            print(f"SSM upload cleanup failed: {error}", file=sys.stderr)
        raise
    return {"remote": remote, "bytes": len(data), "sha256": digest}


def fetch(transport, remote, local):
    destination = Path(local)
    if destination.exists():
        raise FileExistsError(f"{destination} exists; fetched files are never overwritten")
    metadata = json.loads(transport.script(
        "import hashlib, json, os\n"
        f"data = open({remote!r}, 'rb').read()\n"
        "print(json.dumps({'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}))"))
    size = metadata["size"]
    if type(size) is not int or size < 0:
        raise ValueError("invalid remote file size")
    chunks = []
    for offset in range(0, size, CHUNK):
        encoded = transport.script(
            f"import base64; f = open({remote!r}, 'rb'); f.seek({offset}); "
            f"print(base64.b64encode(f.read({CHUNK})).decode())")
        chunks.append(base64.b64decode(encoded.strip(), validate=True))
    data = b"".join(chunks)
    if len(data) != size or hashlib.sha256(data).hexdigest() != metadata["sha256"]:
        raise ValueError("fetched file was truncated or corrupted")
    with open(destination, "xb") as stream:
        stream.write(data)
    return {"local": str(destination), "bytes": size, "sha256": metadata["sha256"]}


def run(ssm, script, timeout):
    """Runs a bash script and waits up to `timeout` seconds for it."""
    response = ssm.api("send-command", "--instance-ids", ssm.instance,
                       "--document-name", "AWS-RunShellScript", "--timeout-seconds", "60",
                       "--parameters", json.dumps({"commands": [Path(script).read_text()],
                                                   "executionTimeout": [str(timeout)]}))
    command_id = response["Command"]["CommandId"]
    print(f"SSM command: {command_id}", file=sys.stderr, flush=True)
    deadline = time.monotonic() + timeout + 120
    while time.monotonic() < deadline:
        try:
            result = ssm.api("get-command-invocation", "--command-id", command_id,
                             "--instance-id", ssm.instance)
        except RuntimeError as error:
            if "InvocationDoesNotExist" not in str(error):
                raise
            time.sleep(2)
            continue
        if result["Status"] not in ("Pending", "InProgress", "Delayed"):
            return {"command_id": command_id, "status": result["Status"],
                    "response_code": result["ResponseCode"],
                    "stdout_tail": result["StandardOutputContent"][-4000:],
                    "stderr_tail": result["StandardErrorContent"][-4000:]}
        time.sleep(10)
    ssm.api("cancel-command", "--command-id", command_id, "--instance-ids", ssm.instance)
    raise TimeoutError(f"SSM command timed out: {command_id}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--instance", required=True)
    commands = parser.add_subparsers(dest="action", required=True)
    up = commands.add_parser("upload")
    up.add_argument("local")
    up.add_argument("remote")
    down = commands.add_parser("fetch")
    down.add_argument("remote")
    down.add_argument("local")
    script = commands.add_parser("run")
    script.add_argument("script")
    script.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", args.instance):
        parser.error("instance must be one explicit EC2 instance ID")
    ssm = SSM(args.profile, args.region, args.instance)
    if args.action == "upload":
        result = upload(ssm, args.local, args.remote)
    elif args.action == "fetch":
        result = fetch(ssm, args.remote, args.local)
    else:
        result = run(ssm, args.script, args.timeout)
    print(json.dumps(result))
    return 0 if args.action != "run" or (result["status"] == "Success" and result["response_code"] == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
