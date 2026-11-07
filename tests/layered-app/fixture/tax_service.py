#!/usr/bin/env python3
"""A stand-in for the tax-rate service the example calls, for local runs
and for tests/layered-app: GET /rates/JP with the bearer token in the given
file answers {"rate_percent": 10}; another token gets 401.

    python3 tax_service.py config/tax-token      # listens on 127.0.0.1:8090
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class TaxService:
    def __init__(self, token, port=0):
        service = self
        self.token = token
        self.rate_percent = 10
        # Seconds each answer waits, for tests that need calls in flight.
        self.delay_seconds = 0

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                time.sleep(service.delay_seconds)
                if self.headers.get("Authorization") != f"Bearer {service.token}":
                    status, body = 401, b"{}"
                elif self.path != "/rates/JP":
                    status, body = 404, b"{}"
                else:
                    status, body = 200, json.dumps({"rate_percent": service.rate_percent}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]

    def start(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


if __name__ == "__main__":
    with open(sys.argv[1]) as file:
        token = file.read().rstrip("\n")
    TaxService(token, 8090).server.serve_forever()
