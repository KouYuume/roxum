#!/usr/bin/env python3
"""The release check, and any one of its tests.

    tools/check.py                    # every check (tools/release-check.sh)
    tools/check.py --only test-tcp    # one test, as `zig build test-tcp` runs it
    tools/check.py --list

Each Roc app of every test is built once per backend and allocator, with
`--no-cache` so parallel builds never share Roc's cache. The host lives at one
path (platform/targets/<target>/), so the apps are built in two phases: all of
them against the arena host, then all of them against the tracking host, and
the arena host is put back at the end. A built executable carries its host,
so the verify scripts then run in parallel. Tests with timing thresholds run
afterwards, one variant at a time, with nothing else running.

Checks that use Roc's shared cache (`roc test`, `roc check`, `zig build
test`) run one at a time in a lane of their own, beside the builds. Zig-only
checks run in another lane. Every job writes its output to
zig-out/check/logs/; a failed job's log ends the report.
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "zig-out" / "check"
LOGS = OUT / "logs"
ROC = os.environ.get("ROC_BIN", "roc")
OPTS = ("speed", "dev", "interpreter")
BOTH = ("arena", "tracking")
ARENA = ("arena",)


@dataclass
class Test:
    """A test whose apps are built for each allocator and backend, and whose
    verify command runs once per variant.

    `verify` and `env` may name `{exe:<app>}`, `{opt}`, `{allocator}`,
    `{contract}` (1 for tracking, else 0), and `{out}`, the variant's own
    directory. `checks` run once, before the variants, in the shared-cache
    lane. `timing` marks a test whose thresholds need a machine without the
    builds and the other lanes; such tests run a few at a time at the end.
    `alone` marks a timing test that loads the machine itself (many workers,
    a thousand connections), whose variants run with nothing else."""
    name: str
    apps: dict
    verify: list
    allocators: tuple = BOTH
    opts: tuple = OPTS
    env: dict = field(default_factory=dict)
    checks: list = field(default_factory=list)
    timing: bool = False
    alone: bool = False
    # Apps whose build may exit non-zero, as long as it writes the executable.
    tolerate_build_status: tuple = ()


@dataclass
class Command:
    """A check that is not a matrix of app builds. `lane` is `cache` (uses
    Roc's shared cache), `zig`, or `pool` (safe to run with anything)."""
    name: str
    argv: list
    lane: str
    env: dict = field(default_factory=dict)


def contract_verify(script, *apps):
    return ["python3", script, *[f"{{exe:{app}}}" for app in apps]]


CONTRACT_ENV = {"ROXUM_CONTRACT_ALLOC": "{contract}"}

TESTS = [
    Test("test-m9p1", {"app": "tests/platform-package/app.roc"}, ["python3", "tests/platform-package/verify.py", "{exe:app}"],
         allocators=ARENA, checks=[["bash", "tests/platform-package/checks.sh"]]),
    Test("test-m9p4", {"app": "integrations/roxum-sse/example/app.roc"},
         ["python3", "integrations/roxum-sse/example/verify.py", "{exe:app}"], allocators=ARENA,
         checks=[["bash", "integrations/roxum-sse/example/checks.sh"]]),
    Test("test-m9-1", {"app": "tests/middleware/app.roc"}, contract_verify("tests/middleware/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-stages", {"app": "tests/stages/app.roc"}, contract_verify("tests/stages/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-input", {"app": "tests/input/app.roc"}, contract_verify("tests/input/verify.py", "app"), env=CONTRACT_ENV, timing=True),
    Test("test-url-encoded", {"app": "tests/url-encoded/app.roc"},
         ["python3", "tests/url-encoded/verify.py", "{exe:app}"], env=CONTRACT_ENV),
    Test("test-acceptance", {"app": "tests/acceptance/app.roc"}, contract_verify("tests/acceptance/verify.py", "app"), env=CONTRACT_ENV, timing=True),
    Test("test-replies", {"app": "tests/replies/app.roc"}, contract_verify("tests/replies/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-tags", {"app": "tests/tags/app.roc"}, contract_verify("tests/tags/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-middleware-example", {"app": "examples/middleware/app.roc"},
         contract_verify("tests/middleware-example/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-router-scopes", {"app": "tests/router-scopes/app.roc", "fallback": "tests/router-scopes/fallback-app.roc"},
         contract_verify("tests/router-scopes/verify.py", "app", "fallback"), env=CONTRACT_ENV),
    Test("test-m9-2", {"app": "tests/router-middleware/app.roc", "default": "tests/router-middleware/default-app.roc"},
         contract_verify("tests/router-middleware/verify.py", "app", "default"), env=CONTRACT_ENV),
    Test("test-m9-3", {"app": "integrations/roxum-set-header/example/app.roc"},
         contract_verify("integrations/roxum-set-header/example/verify.py", "app"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-set-header/package/main.roc"]]),
    Test("test-m9-3b", {"app": "integrations/roxum-trace/example/app.roc"},
         contract_verify("integrations/roxum-trace/example/verify.py", "app"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-trace/package/main.roc"]]),
    Test("test-cookie", {"app": "integrations/roxum-cookie/example/app.roc"},
         contract_verify("integrations/roxum-cookie/example/verify.py", "app"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-cookie/package/main.roc"]]),
    Test("test-concurrency-limit", {"app": "integrations/roxum-concurrency-limit/example/app.roc"},
         contract_verify("integrations/roxum-concurrency-limit/example/verify.py", "app"), env=CONTRACT_ENV, timing=True,
         checks=[[ROC, "test", "integrations/roxum-concurrency-limit/package/main.roc"]]),
    Test("test-rate-limit", {"app": "integrations/roxum-rate-limit/example/app.roc"},
         contract_verify("integrations/roxum-rate-limit/example/verify.py", "app"), env=CONTRACT_ENV, timing=True,
         checks=[[ROC, "test", "integrations/roxum-rate-limit/package/main.roc"]]),
    Test("test-m9-4a", {"app": "integrations/roxum-normalize-path/example/app.roc"},
         contract_verify("integrations/roxum-normalize-path/example/verify.py", "app"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-normalize-path/package/main.roc"]]),
    Test("test-m9-4b", {"app": "integrations/roxum-cors/example/app.roc"},
         contract_verify("integrations/roxum-cors/example/verify.py", "app"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-cors/package/main.roc"]]),
    Test("test-m11a", {"app": "tests/timeouts/app.roc", "zero": "tests/timeouts/zero-app.roc"},
         ["python3", "tests/timeouts/verify.py", "{exe:app}", "{exe:zero}"], allocators=ARENA, timing=True),
    Test("test-stream-limit", {"app": "tests/stream-limit/app.roc", "zero": "tests/stream-limit/zero-app.roc",
                               "waiting": "tests/stream-limit/waiting-app.roc"},
         ["python3", "tests/stream-limit/verify.py", "{exe:app}", "{exe:zero}", "{exe:waiting}"]),
    Test("test-files", {"app": "tests/files/app.roc"}, ["python3", "tests/files/verify.py", "{exe:app}"], env=CONTRACT_ENV),
    Test("test-compression", {"app": "tests/compression/app.roc"}, ["python3", "tests/compression/verify.py", "{exe:app}"], env=CONTRACT_ENV),
    Test("test-file-secret", {"app": "tests/file-secret/app.roc"}, contract_verify("tests/file-secret/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-config", {"app": "tests/config/app.roc"}, contract_verify("tests/config/verify.py", "app"), env=CONTRACT_ENV,
         checks=[["bash", "tests/config/checks.sh"]]),
    Test("test-listen-options", {"app": "tests/listen-options/app.roc"}, ["python3", "tests/listen-options/verify.py", "{exe:app}"],
         allocators=ARENA),
    Test("test-graceful-shutdown", {"app": "tests/graceful-shutdown/app.roc"},
         contract_verify("tests/graceful-shutdown/verify.py", "app"), env=CONTRACT_ENV, timing=True),
    Test("test-admission", {"app": "tests/admission/app.roc"}, contract_verify("tests/admission/verify.py", "app"),
         env=CONTRACT_ENV, timing=True),
    Test("test-observability", {"app": "tests/observability/app.roc"}, contract_verify("tests/observability/verify.py", "app"),
         env=CONTRACT_ENV, timing=True),
    Test("test-unix-socket", {"app": "tests/unix-socket/app.roc"}, contract_verify("tests/unix-socket/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-ipv6", {"app": "tests/ipv6/app.roc"}, contract_verify("tests/ipv6/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-tcp", {"app": "tests/tcp/app.roc"}, ["bash", "tests/tcp/variant.sh", "{exe:app}", "{out}"],
         env=CONTRACT_ENV, timing=True),
    Test("test-http-client", {"app": "tests/http-client/app.roc"},
         ["bash", "tests/http-client/variant.sh", "{exe:app}", "{out}"], env=CONTRACT_ENV, timing=True),
    Test("test-postgres", {"app": "integrations/roxum-postgres/example/app.roc", "protocol": "integrations/roxum-postgres/tests/protocol.roc"},
         ["python3", "integrations/roxum-postgres/example/run.py", "{allocator}", "{exe:app}", "{exe:protocol}"], timing=True,
         checks=[[ROC, "test", "integrations/roxum-postgres/package/main.roc"]]),
    Test("test-layered-app", {"app": "tests/layered-app/fixture/app.roc"},
         ["python3", "tests/layered-app/run.py", "{opt}", "{exe:app}"], allocators=ARENA,
         checks=[[ROC, "test", "tests/layered-app/fixture/domain/product/Product.roc"]]),
    Test("test-crud-service", {"app": "tests/layered-app/fixture/app.roc"},
         ["python3", "tests/crud-service/run.py", "{opt}", "{exe:app}"], allocators=ARENA, timing=True),
    Test("test-m11b", {"app": "integrations/roxum-proxy-headers/example/app.roc",
                       "untrusted": "integrations/roxum-proxy-headers/example/untrusted-app.roc"},
         contract_verify("integrations/roxum-proxy-headers/example/verify.py", "app", "untrusted"), env=CONTRACT_ENV,
         checks=[[ROC, "test", "integrations/roxum-proxy-headers/package/main.roc"]]),
    Test("test-m9b-4", {"app": "tests/debug/app.roc"}, contract_verify("tests/debug/verify.py", "app"), env=CONTRACT_ENV,
         tolerate_build_status=("app",)),
    Test("test-m9b-2", {"app": "tests/static/app.roc"}, contract_verify("tests/static/verify.py", "app"), env=CONTRACT_ENV),
    Test("test-m9b-5", {"app": "examples/ddd/app.roc"}, ["python3", "tests/ddd/run.py", "{allocator}", "{exe:app}"],
         checks=[["bash", "tests/ddd/checks.sh"]]),
    Test("test-m13b", {"routing": "tests/guide/routing.roc", "extractors": "tests/guide/extractors.roc",
                       "middleware": "tests/guide/middleware.roc"},
         ["bash", "-c", 'python3 tests/guide/verify.py routing "$1" && python3 tests/guide/verify.py extractors "$2" '
          '&& python3 tests/guide/verify.py middleware "$3"', "guide", "{exe:routing}", "{exe:extractors}", "{exe:middleware}"],
         allocators=ARENA,
         checks=[["bash", "-c", f'{ROC} docs platform/main.roc --output="$(mktemp -d)" >/dev/null']]),
    Test("test-e2e", {"echo": "tests/e2e/app.roc"},
         ["zig", "build", "test-e2e", "-Dopt={opt}", "-Dcontract-alloc={contract_bool}", "-De2e-readiness=false"],
         env={"ROXUM_PREBUILT_EXE": "{exe:echo}"}, timing=True, alone=True),
]

COMMANDS = [
    Command("test-http2-roc", ["zig", "build", "test-http2-roc"], "zig"),
    Command("test-http2-wire", ["zig", "build", "test-http2-wire"], "zig"),
    Command("test-abi", ["zig", "build", "test-abi"], "zig"),
    Command("test", ["zig", "build", "test"], "cache"),
    Command("test-m9p2", ["bash", "tests/platform-package/identity/run.sh"], "pool"),
    Command("test-m9p3", ["bash", "tests/platform-package/manifest/run.sh"], "pool"),
    Command("test-m13a", ["bash", "tests/release/run.sh"], "pool"),
    Command("test-local-check", ["python3", "tests/local-check/test_verify_local_check.py"], "pool"),
    Command("test-agent-policy", ["python3", "tests/local-check/test_agent_policy.py"], "pool"),
    Command("test-http1-release", ["zig", "build", "test-http1-release"], "zig"),
    Command("fuzz", ["tools/fuzz.sh", "10000"], "zig"),
]
# The thread sanitizer runs on Linux only: under some macOS environments a
# fault never becomes a signal (a parent's exception port takes it), and
# the sanitized test then spins instead of ending.
if sys.platform.startswith("linux"):
    COMMANDS.append(Command("test-tsan", ["zig", "build", "test-tsan"], "zig"))


def roc_target():
    return subprocess.run(["tools/roc-target.sh"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


class Report:
    """Durations and outcomes of every job, written as they finish."""

    def __init__(self):
        self.lock = threading.Lock()
        self.rows = []

    def add(self, name, seconds, ok):
        with self.lock:
            self.rows.append((name, seconds, ok))
            print(f"{'PASS' if ok else 'FAIL'} {seconds:7.1f}s {name}", flush=True)


REPORT = Report()


def run_job(name, argv, env=None, built=None):
    """Runs one job with its output in its own log. True when it passed:
    it exited 0, or, given `built`, that file exists (a build that warns
    exits non-zero)."""
    LOGS.mkdir(parents=True, exist_ok=True)
    log = LOGS / f"{name.replace('/', '-')}.log"
    started = time.monotonic()
    with open(log, "w") as output:
        output.write(f"$ {' '.join(argv)}\n")
        output.flush()
        result = subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                env={**os.environ, **(env or {})})
    ok = result.returncode == 0 if built is None else built.exists()
    REPORT.add(name, time.monotonic() - started, ok)
    return ok


def executable(test, app, allocator, opt):
    return OUT / "bin" / test.name / f"{app}-{allocator}-{opt}"


def substitute(value, test, allocator, opt):
    out = OUT / "run" / test.name / f"{allocator}-{opt}"
    replacements = {
        "{opt}": opt,
        "{allocator}": allocator,
        "{contract}": "1" if allocator == "tracking" else "0",
        "{contract_bool}": "true" if allocator == "tracking" else "false",
        "{out}": str(out),
    }
    for app in test.apps:
        replacements[f"{{exe:{app}}}"] = str(executable(test, app, allocator, opt))
    for key, replacement in replacements.items():
        value = value.replace(key, replacement)
    return value


def install_host(allocator):
    argv = ["zig", "build", "host"] + (["-Dcontract-alloc=true"] if allocator == "tracking" else [])
    if not run_job(f"host-{allocator}", argv):
        raise SystemExit(f"the {allocator} host did not build; see {LOGS}")


def build_app(test, app, allocator, opt, target):
    path = executable(test, app, allocator, opt)
    path.parent.mkdir(parents=True, exist_ok=True)
    argv = [ROC, "build", "--no-cache", f"--opt={opt}", f"--target={target}", f"--output={path}", test.apps[app]]
    name = f"build/{test.name}/{app}-{allocator}-{opt}"
    return run_job(name, argv, built=path if app in test.tolerate_build_status else None)


def build_all(tests, target, jobs):
    """Builds every app of `tests` against each host in turn."""
    ok = True
    allocators = [allocator for allocator in BOTH if any(allocator in test.allocators for test in tests)]
    for allocator in allocators:
        install_host(allocator)
        builds = [(test, app, allocator, opt) for test in tests if allocator in test.allocators
                  for app in test.apps for opt in test.opts]
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            results = list(pool.map(lambda item: build_app(*item, target), builds))
        ok = ok and all(results)
    if allocators and allocators[-1] != "arena":
        install_host("arena")
    return ok


def variants(test):
    return [(allocator, opt) for allocator in test.allocators for opt in test.opts]


def verify(test, allocator, opt):
    out = OUT / "run" / test.name / f"{allocator}-{opt}"
    out.mkdir(parents=True, exist_ok=True)
    argv = [substitute(part, test, allocator, opt) for part in test.verify]
    env = {key: substitute(value, test, allocator, opt) for key, value in test.env.items()}
    return run_job(f"{test.name}/{allocator}-{opt}", argv, env)


def run_lane(jobs_list):
    """Runs (name, argv, env) jobs one after another; True when all passed."""
    return all([run_job(*job) for job in jobs_list])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="run one test or command by its zig build step name")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--timing-jobs", type=int, default=3,
                        help="variants of timing tests to run at once, after everything else has finished")
    arguments = parser.parse_args()
    if arguments.list:
        for item in TESTS + COMMANDS:
            print(item.name)
        return

    tests = TESTS
    commands = COMMANDS
    if arguments.only:
        tests = [test for test in TESTS if test.name == arguments.only]
        commands = [command for command in COMMANDS if command.name == arguments.only]
        if not tests and not commands:
            raise SystemExit(f"no test or command named {arguments.only}")
    else:
        shutil.rmtree(OUT, ignore_errors=True)
    shutil.rmtree(LOGS, ignore_errors=True)
    for test in tests:
        shutil.rmtree(OUT / "bin" / test.name, ignore_errors=True)
        shutil.rmtree(OUT / "run" / test.name, ignore_errors=True)

    target = roc_target()
    started = time.monotonic()
    # Only a full run on a committed tree is recorded for the pre-push hook
    # (tools/verify_local_check.py).
    tree = committed_tree() if not arguments.only and os.environ.get("ROC_SRC") else None
    ok = True
    if not arguments.only and os.environ.get("ROC_SRC"):
        ok = run_lane([("toolchain", ["tools/check-roc-toolchain.sh"], None),
                       ("glue", ["tools/regen-glue.sh", "--check"], None)]) and ok

    # Beside the builds and the parallel verifies: the shared-cache lane and
    # the Zig lane. Both end before the timing tests, which need a quiet
    # machine.
    cache_lane = [(f"{test.name}/checks-{index}", check, None) for test in tests for index, check in enumerate(test.checks)]
    cache_lane += [(command.name, command.argv, command.env) for command in commands if command.lane == "cache"]
    if not arguments.only and target in ("x64musl", "arm64mac"):
        cache_lane.append(("fuzz-router", ["zig", "build", "fuzz-router"], None))
    zig_lane = [(command.name, command.argv, command.env) for command in commands if command.lane == "zig"]
    pool_commands = [(command.name, command.argv, command.env) for command in commands if command.lane == "pool"]

    # The checks in the cache lane build apps too: give them a host first.
    if any(test.checks for test in tests):
        install_host("arena")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as lanes:
        cache_result = lanes.submit(run_lane, cache_lane)
        zig_result = lanes.submit(run_lane, zig_lane)
        ok = build_all(tests, target, arguments.jobs) and ok
        quiet = [(test, allocator, opt) for test in tests if not test.timing for allocator, opt in variants(test)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.jobs) as pool:
            command_results = [pool.submit(run_job, *job) for job in pool_commands]
            results = list(pool.map(lambda item: verify(*item), quiet))
            ok = all(results) and all(future.result() for future in command_results) and ok
        ok = cache_result.result() and ok
        ok = zig_result.result() and ok

    timed = [(test, allocator, opt) for test in tests if test.timing and not test.alone for allocator, opt in variants(test)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.timing_jobs) as pool:
        ok = all(list(pool.map(lambda item: verify(*item), timed))) and ok
    for test in tests:
        if test.alone:
            for allocator, opt in variants(test):
                ok = verify(test, allocator, opt) and ok
    if not arguments.only or arguments.only == "test-e2e":
        ok = run_job("test-e2e/readiness", ["python3", "tests/e2e/supervisor_readiness_test.py", shutil.which("zig") or "zig"]) and ok

    rows = sorted(REPORT.rows, key=lambda row: -row[1])
    print(f"\n{len(rows)} jobs in {time.monotonic() - started:.0f}s; the slowest:")
    for name, seconds, passed in rows[:12]:
        print(f"  {seconds:7.1f}s {'' if passed else 'FAIL '}{name}")
    failed = [name for name, _, passed in REPORT.rows if not passed]
    if failed:
        for name in failed:
            log = LOGS / f"{name.split(' ')[0].replace('/', '-')}.log"
            print(f"\n===== FAIL {name} ({log}) =====")
            if log.exists():
                print("\n".join(log.read_text(errors="replace").splitlines()[-40:]))
        raise SystemExit(1)
    print(f"\nPASS — {'release checks' if not arguments.only else arguments.only} ({target})")
    if not arguments.only:
        record_pass(tree, target)


def committed_tree():
    """HEAD's tree when the working tree has no changes, else None."""
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout
    if status.strip():
        return None
    return subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout.strip()


def record_pass(tree, target):
    """Records the tree the checks passed on, for the pre-push hook. A tree
    that changed during the run, or a run without ROC_SRC (which skips the
    toolchain and glue checks), is not recorded."""
    if tree is None or committed_tree() != tree:
        reason = "ROC_SRC is not set" if not os.environ.get("ROC_SRC") else "the tree had uncommitted changes or changed during the run"
        print(f"not recorded for pushing: {reason}")
        return
    record = ROOT / "zig-out" / "check-passed.json"
    record.write_text(json.dumps({"tree": tree, "target": target,
                                  "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, indent=2) + "\n")
    print(f"recorded for pushing: tree {tree[:12]}")


if __name__ == "__main__":
    main()
