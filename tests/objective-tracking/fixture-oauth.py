#!/usr/bin/env python3
"""Disposable loopback Shomei token contract; no production credentials."""
import base64
import http.server
import http.client
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/v1/agent-actions/authorize":
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 4096:
                self.send_response(413)
                self.end_headers()
                return
            body = self.rfile.read(length)
            connection = http.client.HTTPConnection("127.0.0.1", int(sys.argv[2]), timeout=5)
            try:
                connection.request("POST", self.path, body, {"Content-Type": "application/json", "Authorization": self.headers.get("Authorization", "")})
                result = connection.getresponse()
                output = result.read(8193)
                if len(output) > 8192:
                    raise ValueError("oversized fixture response")
                with Path(sys.argv[3]).open("a") as evidence:
                    evidence.write(f"authorize status {result.status}\n")
                self.send_response(result.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(output)))
                self.end_headers()
                self.wfile.write(output)
            finally:
                connection.close()
            return
        expected = "Basic " + base64.b64encode(b"fixture:fixture-secret").decode()
        if self.path != "/oauth/token" or self.headers.get("Authorization") != expected:
            self.send_response(401)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > 4096:
            self.send_response(413)
            self.end_headers()
            return
        form = parse_qs(self.rfile.read(length).decode())
        if form.get("grant_type") != ["client_credentials"] or form.get("scope") != ["kikan-en:authorize-agent-action"]:
            self.send_response(400)
            self.end_headers()
            return
        with Path(sys.argv[3]).open("a") as evidence:
            evidence.write("token status 200\n")
        # mori://shinzui/shomei, shomei-servant/src/Shomei/Servant/OAuth.hs,
        # TokenResponse (artifact URI pending): scope is required; absent
        # refresh/id/issued-token fields are optional for client_credentials.
        body = json.dumps({"access_token": "objective-fixture-token", "token_type": "Bearer", "expires_in": 60,
                           "scope": "kikan-en:authorize-agent-action"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        # TokenHeaders in mori://shinzui/shomei, project-relative
        # shomei-servant/src/Shomei/OAuth/Result.hs (artifact URI pending).
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
