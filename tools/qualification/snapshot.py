#!/usr/bin/env python3
"""Collect bounded public health status from an explicit numeric loopback allowlist."""
import argparse
from datetime import datetime, timezone
import ipaddress
import json
from pathlib import Path
import re
import socket
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def validate_endpoint(endpoint):
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("health URLs must be public HTTP URLs without credentials, query or fragment")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        raise ValueError("health URLs must use a numeric loopback address") from None
    if not address.is_loopback or not parsed.port or parsed.path not in {"/health/live", "/health/ready"}:
        raise ValueError("only explicit loopback ports and /health/live or /health/ready are allowed")
    return endpoint


def collect(endpoints, marker):
    if not re.fullmatch(r"[a-zA-Z0-9_.-]{1,100}", marker):
        raise ValueError("run marker must be a bounded public identifier")
    if not isinstance(endpoints, dict) or not 1 <= len(endpoints) <= 16:
        raise ValueError("health_endpoints must map 1 to 16 service names to URLs")
    # Validate every entry before performing IO. No DNS, proxy, or redirect path
    # can turn a public local health request into arbitrary network access.
    for name, endpoint in endpoints.items():
        if not re.fullmatch(r"[a-zA-Z0-9_.-]{1,64}", name):
            raise ValueError("invalid service name")
        validate_endpoint(endpoint)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    services = []
    for name, endpoint in endpoints.items():
        try:
            with opener.open(endpoint, timeout=2) as response:
                body = response.read(4097)
                status = "healthy" if response.status == 200 and len(body) <= 4096 else "unavailable"
                # Response bodies may contain unexpected data: retain only status
                # and size, never potentially secret diagnostics from a server.
                detail = f"HTTP {response.status}; response {'exceeds limit' if len(body) > 4096 else 'within limit'}"
        except urllib.error.HTTPError as error:
            status, detail = "unavailable", f"HTTP {error.code}"
            error.close()
        except (urllib.error.URLError, TimeoutError, socket.timeout):
            status, detail = "unavailable", "health endpoint unreachable within timeout"
        services.append({"name": name, "status": status, "detail": detail})
    return {"run_marker": marker, "captured_at": datetime.now(timezone.utc).isoformat(),
            "text": "service health report: " + "; ".join(f"{service['name']} {service['status']}" for service in services),
            "services": services}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--marker", required=True)
    args = parser.parse_args()
    try:
        inventory = json.loads(args.inventory.read_text())
        print(json.dumps(collect(inventory["health_endpoints"], args.marker), indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"snapshot: {error}\n")


if __name__ == "__main__":
    main()
