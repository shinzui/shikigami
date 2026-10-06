import importlib.util
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import unittest

spec = importlib.util.spec_from_file_location("snapshot", Path(__file__).with_name("snapshot.py"))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def test_refuses_non_allowlisted_network_access(self):
        for url in ["http://example.com:80/health/ready", "http://127.0.0.1/health/ready",
                    "http://127.0.0.1:80/secrets", "http://user:secret@127.0.0.1:80/health/ready",
                    "http://127.0.0.1:80/health/ready?token=secret", "https://127.0.0.1:80/health/ready"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                snapshot.validate_endpoint(url)

    def test_status_is_bounded_and_redirects_never_escape(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/health/live":
                    self.send_response(302)
                    self.send_header("Location", "http://example.com/secret")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"secret-body-not-for-evidence")

            def log_message(self, *_args):
                pass

        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                result = snapshot.collect({"ready": base + "/health/ready", "redirect": base + "/health/live"}, "test-01")
                self.assertEqual([item["status"] for item in result["services"]], ["healthy", "unavailable"])
                self.assertNotIn("secret-body", str(result))
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
