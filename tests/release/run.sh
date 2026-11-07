#!/usr/bin/env bash
# Builds the release's bundles, serves them on localhost, and builds and runs
# an app that names the platform and an integration by URL, the way a user
# would.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-release.XXXXXX")
server_pid=
cleanup() {
	if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
	rm -rf "$task_tmp"
}
trap cleanup EXIT

mkdir -p zig-out/release

# Roc allows plain HTTP only for a loopback host. The URL names the address
# the server binds: with `localhost`, Roc 2026-10-09 picks `::1` from
# /etc/hosts in a Linux container and fails without trying 127.0.0.1. The
# server starts first: the release URL the integrations' bundles name has
# its port.
# Not `python3 -m http.server`: binding, it looks up the host's name with
# `socket.getfqdn`, which can stall on a CI runner's resolver.
python3 -u -c '
import functools, http.server, socketserver, sys

class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with Server(("127.0.0.1", 0), handler) as server:
    print(f"Serving on port {server.server_address[1]}")
    server.serve_forever()
' zig-out/release >"$task_tmp/http.log" 2>&1 &
server_pid=$!
# Waits by the clock, not a count of sleeps, which a loaded machine stretches.
port=
started=$SECONDS
while (( SECONDS - started < 30 )); do
	port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$task_tmp/http.log" | head -n 1)
	[[ -n "$port" ]] && break
	sleep 0.1
done
if [[ -z "$port" ]]; then
	echo "the bundle server did not start within 30 s ($(python3 --version)); it printed:" >&2
	cat "$task_tmp/http.log" >&2
	exit 1
fi
echo "the bundle server started within $(( SECONDS - started )) s"

zig build release -Drelease-url="http://127.0.0.1:$port"
bundle=$(python3 -c 'import json; print(json.load(open("zig-out/release/release.json"))["platform"]["file"])')
set_header_url=$(python3 -c 'import json; print(next(item["url"] for item in json.load(open("zig-out/release/release.json"))["integrations"] if item["name"] == "roxum-set-header"))')

sed -e "s#@PLATFORM_URL@#http://127.0.0.1:$port/$bundle#" -e "s#@SET_HEADER_URL@#$set_header_url#" tests/release/app.roc.in > "$task_tmp/app.roc"
for opt in speed dev interpreter; do
	executable="$task_tmp/app-$opt"
	# Fresh caches make Roc download and verify the bundle. Roc keeps
	# downloaded packages under XDG_CACHE_HOME, apart from ROC_CACHE_DIR.
	ROC_CACHE_DIR="$task_tmp/roc-cache-$opt" XDG_CACHE_HOME="$task_tmp/xdg-cache-$opt" \
		"$roc_bin" build --opt="$opt" --output="$executable" "$task_tmp/app.roc" >/dev/null
	python3 tests/release/verify.py "$executable"
	echo "M13a bundle $opt: PASS"
done
# Each build must have fetched the bundle; a cache hit would skip the check.
downloads=$(grep -c "GET /$bundle" "$task_tmp/http.log" || true)
if [[ "$downloads" -ne 3 ]]; then
	echo "expected 3 bundle downloads, the server saw $downloads" >&2
	exit 1
fi
