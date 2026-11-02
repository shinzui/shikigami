#!/usr/bin/env python3
"""Served two-service acceptance on disposable data, invoked only by with-rei.sh."""
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

assert os.environ.get("SHIKIGAMI_TEST_REI_ISOLATED") == "masterplan-18"
REPO = Path(sys.argv[1])
SERVER, WORKER, MIGRATE, CLI = sys.argv[2:]
REI = os.environ["SHIKIGAMI_TEST_REI_BASE_URL"]
REI_TOKEN = os.environ["SHIKIGAMI_TEST_REI_TOKEN"]
assert REI.startswith("http://127.0.0.1:")


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def request(base, path, body=None, token=None, expected=(200,), method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method or ("POST" if body is not None else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=25) as reply:
            status, data = reply.status, reply.read()
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    assert status in expected, (path, status, data[:500])
    return json.loads(data) if data else None


def wait(action, accepted, seconds=35):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = action()
            if accepted(last):
                return last
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(.1)
    raise AssertionError(("bounded convergence failed", last))


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    mode = "pass"
    posts = []
    gets = 0
    lock = threading.Lock()

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.command == "GET":
            with self.lock:
                type(self).gets += 1
        if self.mode == "missing" and self.command == "GET" and self.path.startswith("/api/v2/intentions/") and self.path.count("/") == 4:
            payload = json.dumps({"type":"about:blank","title":"Not found","status":404,"detail":"disposable lost access","code":"not_found","retryable":False}).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/problem+json")
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.mode == "offline":
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"{}")
            return
        target = urllib.parse.urlparse(REI)
        connection = http.client.HTTPConnection(target.hostname, target.port, timeout=20)
        connection.request(self.command, self.path, body, {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")})
        reply = connection.getresponse()
        payload = reply.read()
        action_post = self.command == "POST" and self.path.endswith("/actions")
        if action_post:
            assert reply.status in (200, 201), (reply.status, payload[:500])
            with self.lock:
                self.posts.append(json.loads(payload))
        self.send_response(reply.status)
        self.send_header("Content-Type", reply.getheader("Content-Type", "application/json"))
        self.end_headers()
        if action_post and self.mode == "lose":
            payload = b"{committed-response-lost"
        self.wfile.write(payload)
        connection.close()

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="shikigami-trackers-") as temporary, contextlib.ExitStack() as cleanup:
    root = Path(temporary)
    runtime = root / "runtime"
    runtime.mkdir()
    shutil.copytree(REPO / "schema", runtime / "schema")
    (runtime / "agents").mkdir()
    pgdata, pgsocket = root / "postgres", root / "socket"
    pgsocket.mkdir()
    subprocess.run(["initdb", "--auth=trust", "--no-locale", "--encoding=UTF8", "-D", str(pgdata)], check=True, stdout=subprocess.DEVNULL)
    pgport = port()
    subprocess.run(["pg_ctl", "-D", str(pgdata), "-l", str(root / "postgres.log"), "-o", f"-k {pgsocket} -p {pgport} -h ''", "start", "-w"], check=True, stdout=subprocess.DEVNULL)
    cleanup.callback(lambda: subprocess.run(["pg_ctl", "-D", str(pgdata), "stop", "-m", "fast"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    subprocess.run(["createdb", "-h", str(pgsocket), "-p", str(pgport), "shikigami"], check=True)
    connection = f"host={pgsocket} port={pgport} dbname=shikigami user={os.environ.get('USER', subprocess.check_output(['id','-un'],text=True).strip())}"
    environment = dict(os.environ, PG_CONNECTION_STRING=connection, DATABASE_URL=connection, SHIKIGAMI_REI_TRACKER_TOKEN=REI_TOKEN)
    with (root / "migrate.log").open("w") as log:
        subprocess.run([MIGRATE, "up"], env=environment, cwd=runtime, stdout=log, stderr=log, check=True)
    proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    thread.start()
    cleanup.callback(proxy.server_close)
    cleanup.callback(proxy.shutdown)
    endpoint = "http://127.0.0.1:" + str(proxy.server_port)
    operator = {"tag": "LocalOperator", "contents": "tracker-worker"}
    caller = {"tag": "VerifiedCaller", "contents": "tracker-user"}
    tracker = {"enabled": "TrackersEnabled", "connections": [{"connectionId": "rei-fixture", "incarnation": "installation-one", "provider": "rei-v2-objectives/1", "endpoint": endpoint, "account": "fixture-account", "credential": "env:SHIKIGAMI_REI_TRACKER_TOKEN", "useGrants": [operator, caller], "exportGrants": [operator, caller]}], "pollSeconds": 1, "batchSize": 4, "reconciliationOperators": [operator, caller]}
    environment["SHIKIGAMI_OBJECTIVE_TRACKERS"] = json.dumps(tracker)
    environment["SHIKIGAMI_OBJECTIVES"] = json.dumps({"enabled": True, "operator": "tracker-worker", "administration": "AdministerAll"})
    api_token = secrets.token_urlsafe(32)
    environment["SHIKIGAMI_API_TOKEN"] = api_token
    processes = {}

    def stop(name):
        process = processes.pop(name, None)
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    cleanup.callback(lambda: [stop(name) for name in list(processes)])
    api_caller = "tracker-user"
    apiport, healthport = port(), port()
    api = "http://127.0.0.1:" + str(apiport)

    def start(name):
        stop(name)
        args = [SERVER, "--host", "127.0.0.1", "--port", str(apiport), "--set", "http.auth.mode=bearer", "--set", "http.auth.caller=" + api_caller] if name == "server" else [WORKER, "--set", "health.port=" + str(healthport)]
        args += ["--set", "agents.directory=agents"]
        log = cleanup.enter_context((root / (name + ".log")).open("a"))
        processes[name] = subprocess.Popen(args, env=environment, cwd=runtime, stdout=log, stderr=log)
        if name == "server":
            wait(lambda: request(api, "/health/ready"), lambda _: True)

    def call(path, body=None, expected=(200,), method=None):
        return request(api, path, body, api_token, expected, method)

    def rei(path, body=None, expected=(200,), method=None):
        return request(REI, "/api/v2" + path, body, REI_TOKEN, expected, method)

    def cli(*args):
        result = subprocess.run([CLI, "objectives", "trackers", *args, "--json"], env=environment, cwd=runtime, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr[-2000:]
        return json.loads(result.stdout)

    def failure_logs(kind, value, traceback):
        if kind:
            for logfile in root.glob("*.log"):
                content = logfile.read_text(errors="replace")[-6000:]
                content = content.replace(REI_TOKEN, "[credential]").replace(api_token, "[credential]")
                print(logfile.name + ":\n" + content, file=sys.stderr)
        return False

    cleanup.push(failure_logs)
    start("server")
    remote = rei("/intentions", {"title": "Disposable linked objective"}, (200, 201))["intentionId"]
    create = json.loads((REPO / "fixtures/qualification/objective-trackers/create.json").read_text())
    objective = call("/objectives", {"format": 1, "operationKey": "create", "request": create}, (201,))["objectiveId"]
    route = "/objectives/" + objective + "/trackers"
    scope = {"connectionId": "rei-fixture", "incarnation": "installation-one", "resourceId": remote, "providerRevision": "rei-v2-objectives/1"}
    policy = {"revision": "shikigami.tracker-mapping/1", "instructions": "ProposeField", "lifecycle": "ProposeField", "publication": "ProgressSummaries"}

    def submit(key, request_body, expected=(200,)):
        return call(route + "/commands", {"format": 1, "operationKey": key, "request": request_body}, expected)

    def command(key, tag, contents=None, expected=(200,)):
        cmd = {"tag": tag}
        if contents is not None:
            cmd["contents"] = contents
        return submit(key, {"tag": "RunCommand", "contents": cmd}, expected)

    def local(key, tag, contents=None, expected=(200,)):
        current = call("/objectives/" + objective)
        cmd = {"tag": tag}
        if contents is not None:
            cmd["contents"] = contents
        return call("/objectives/" + objective + "/commands", {"format": 1, "operationKey": key, "expectedRevision": current["revision"], "command": cmd}, expected)

    def binding():
        return call(route + "/binding-main")

    def histories(name):
        result, cursor = [], None
        while True:
            suffix = "?first=100" + ("&after=" + urllib.parse.quote(cursor) if cursor else "")
            page = call(route + "/binding-main/" + name + suffix)
            result.extend(edge["node"]["preview"] for edge in page["edges"])
            if not page["pageInfo"]["hasNextPage"]:
                return result
            cursor = page["pageInfo"]["endCursor"]

    def proposals():
        return [row for row in histories("proposals") if row["state"] == "AwaitingDecision"]

    def deliveries():
        return histories("deliveries")

    def operation_finished(key):
        value = wait(lambda: call(route + "/operations/" + key), lambda row: row["state"] == "Finished")
        assert value["failure"] is None, value
        return value

    bind_request = {"tag": "RunCommand", "contents": {"tag": "Bind", "contents": ["binding-main", scope, policy]}}
    submit("bind", bind_request, (202,))
    submit("bind", bind_request, (200,))
    assert not call(route)["edges"]
    start("worker")
    operation_finished("bind")
    assert binding()["localInstructions"]["preview"] == "local guidance"
    local("block", "SetBlocked", True)
    wait(deliveries, lambda rows: len(rows) == 1 and rows[0][1]["state"] == "Delivered")
    assert len(Proxy.posts) == 1
    print("PASS served binding, unchanged initial instructions, one real action and Delivered receipt", flush=True)

    rei("/intentions/" + remote + "/commands/set-note-guidance", {"noteGuidance": "reviewed remote guidance"})
    first = wait(proposals, lambda rows: any(row["change"].get("contents") == "reviewed remote guidance" for row in rows))[0]
    assert binding()["localInstructions"]["preview"] == "local guidance"
    before = call("/objectives/" + objective)
    command("apply", "ApplyProposal", ["binding-main", first["bindingRevision"], first["proposalId"], before["revision"]])
    after = call("/objectives/" + objective)
    assert binding()["localInstructions"]["preview"] == "reviewed remote guidance" and after["revision"] > before["revision"]
    command("apply", "ApplyProposal", ["binding-main", first["bindingRevision"], first["proposalId"], before["revision"]])
    assert not proposals()
    print("PASS reviewed proposal import and original command receipt replay", flush=True)

    rei("/intentions/" + remote + "/commands/set-note-guidance", {"noteGuidance": "racing remote guidance"})
    second = wait(proposals, lambda rows: any(row["change"].get("contents") == "racing remote guidance" for row in rows))[0]
    local("local-edit", "ReviseInstructions", "local concurrent guidance")
    current = call("/objectives/" + objective)
    command("stale-apply", "ApplyProposal", ["binding-main", second["bindingRevision"], second["proposalId"], current["revision"]], (409,))
    command("reject", "RejectProposal", ["binding-main", second["bindingRevision"], second["proposalId"], current["revision"], "keep the explicit local decision"])
    time.sleep(1.2)
    assert not proposals()
    assert binding()["localInstructions"]["preview"] == "local concurrent guidance"
    print("PASS concurrent local edit conflicts and explicit rejection does not repropose", flush=True)

    rei("/intentions/" + remote + "/commands/complete", {}, (200,), method="POST")
    wait(lambda: rei("/intentions/" + remote), lambda row: row["status"] == "completed")
    wait(binding, lambda row: row["binding"]["preview"]["latest"]["snapshot"]["lifecycle"] == "RemoteCompleted")
    assert call("/objectives/" + objective)["status"] != "Completed"
    local("without-evidence", "AcceptCompletion", expected=(400, 409))
    rei("/intentions/" + remote + "/commands/reopen", {})
    print("PASS external completion and reopening preserve independent local acceptance", flush=True)

    # Provider outage while the local service is alive: no agent result depends
    # on Rei availability. Stop dispatchers so no POST is admitted during outage.
    stop("worker")
    Proxy.mode = "offline"
    local("unblock-offline", "SetBlocked", False)
    stop("server")
    Proxy.mode = "pass"
    start("server")
    start("worker")
    wait(deliveries, lambda rows: all(receipt["state"] == "Delivered" for _, receipt in rows))
    count_before = len(Proxy.posts)
    stop("worker")
    Proxy.mode = "lose"
    local("lost-action", "SetBlocked", True)
    start("worker")
    unknown_pair = wait(deliveries, lambda rows: any(receipt["state"] == "Unknown" for _, receipt in rows))
    intent, receipt = next(pair for pair in unknown_pair if pair[1]["state"] == "Unknown")
    assert len(Proxy.posts) == count_before + 1
    stop("worker")
    stop("server")
    Proxy.mode = "pass"
    start("server")
    start("worker")
    time.sleep(1.5)
    assert len(Proxy.posts) == count_before + 1
    action = Proxy.posts[-1]["actionId"]
    submit("verify", {"tag": "Verify", "contents": [intent["publicationId"], action]}, (202,))
    operation_finished("verify")
    attest = [intent["publicationId"], receipt["attempt"]["attemptId"], scope["incarnation"], action, intent["digest"], receipt["revision"], "verified actual remote action after acknowledgement loss"]
    result = command("attest", "AttestDelivery", attest)
    assert command("attest", "AttestDelivery", attest) == result
    assert len(Proxy.posts) == count_before + 1
    wait(deliveries, lambda rows: any(pair[1].get("evidence", {}).get("kind") == "OperatorAttested" for pair in rows if pair[1].get("evidence")))
    print("PASS real response loss, both service restarts, Unknown quarantine, exact verified attestation and zero second POSTs", flush=True)

    rei("/intentions/" + remote + "/commands/abandon", {})
    wait(binding, lambda row: row["binding"]["preview"]["latest"]["snapshot"]["lifecycle"] == "RemoteCancelled")
    assert call("/objectives/" + objective)["status"] != "Cancelled"
    print("PASS external abandonment offers review without local cancellation", flush=True)

    # CLI uses its own configured local operator, not the HTTP caller.
    inspected = cli("inspect", objective, "--binding", "binding-main")
    assert inspected["localStatus"] != "Completed"
    cli("proposals", objective, "binding-main")
    cli("deliveries", objective, "binding-main")
    doc = root / "pause.json"
    revision = binding()["binding"]["preview"]["revision"]
    doc.write_text(json.dumps({"format": 1, "operationKey": "operator-pause", "request": {"tag": "RunCommand", "contents": {"tag": "Pause", "contents": ["binding-main", revision]}}}))
    cli("command", objective, "--file", str(doc))
    cli("command", objective, "--file", str(doc))
    before_pause = len(Proxy.posts)
    local("paused-local-progress", "SetBlocked", False)
    time.sleep(1.2)
    assert len(Proxy.posts) == before_pause
    cli("operation", objective, "operator-pause")
    print("PASS operator CLI inspection, closed command, exact replay and paused export", flush=True)
    # Admit a real request as a coordinator, revoke membership before worker
    # dispatch, and inspect only the fixture's own durable refusal metadata.
    stop("worker")
    reviewer = {"tag": "VerifiedCaller", "contents": "reviewer"}
    local("grant-reviewer", "GrantMember", [reviewer, ["Coordinator"]])
    revision = binding()["binding"]["preview"]["revision"]

    def operator_binding(key, tag, revision):
        doc.write_text(json.dumps({"format":1,"operationKey":key,"request":{"tag":"RunCommand","contents":{"tag":tag,"contents":["binding-main",revision]}}}))
        return cli("command", objective, "--file", str(doc))

    operator_binding("resume-for-reviewed-read", "Resume", revision)
    tracker["connections"][0]["useGrants"].append(reviewer)
    environment["SHIKIGAMI_OBJECTIVE_TRACKERS"] = json.dumps(tracker)
    api_caller = "reviewer"
    start("server")
    revision = binding()["binding"]["preview"]["revision"]
    submit("revoked-observe", {"tag":"Observe","contents":["binding-main",revision]}, (202,))
    api_caller = "tracker-user"
    start("server")
    local("revoke-reviewer", "RevokeMember", reviewer)
    operator_binding("pause-revoked-read", "Pause", revision)
    gets_before = Proxy.gets
    start("worker")

    def refused():
        query = "SELECT control->>'state', control->'failure'->>'tag' FROM shikigami.objective_tracker_commands WHERE operation_key='revoked-observe'"
        return subprocess.check_output(["psql", "-d", connection, "-At", "-c", query], env=environment, text=True).strip()

    wait(refused, lambda value: value == "Finished|TrackerDenied")
    assert Proxy.gets == gets_before
    api_caller = "reviewer"
    start("server")
    call(route + "/operations/revoked-observe", expected=(404,))
    api_caller = "tracker-user"
    start("server")
    print("PASS accepted caller revocation before real worker dispatch performs zero provider reads", flush=True)

    stop("worker")
    revision = binding()["binding"]["preview"]["revision"]
    operator_binding("resume-before-export-revocation", "Resume", revision)
    local("progress-before-export-revocation", "SetBlocked", True)
    tracker["connections"][0]["exportGrants"] = []
    environment["SHIKIGAMI_OBJECTIVE_TRACKERS"] = json.dumps(tracker)
    posts_before = len(Proxy.posts)
    start("server")
    start("worker")
    wait(deliveries, lambda rows: any(receipt["state"] == "Suppressed" for _, receipt in rows))
    assert len(Proxy.posts) == posts_before
    Proxy.mode = "missing"
    wait(lambda: histories("observations"), lambda rows: any(row[0] == "missing" for row in rows))
    assert any(receipt.get("evidence", {}).get("kind") == "OperatorAttested" for _, receipt in deliveries() if receipt.get("evidence"))
    assert call("/objectives/" + objective)["status"] != "Cancelled"
    Proxy.mode = "pass"
    print("PASS revoked export suppresses pending work; remote access loss retains observations and delivery evidence", flush=True)

    second_connection = dict(tracker["connections"][0], connectionId="rei-second", incarnation="installation-two", account="fixture-second-scope")
    tracker["connections"].append(second_connection)
    environment["SHIKIGAMI_OBJECTIVE_TRACKERS"] = json.dumps(tracker)
    start("server")
    start("worker")
    second_objective = call("/objectives", {"format":1,"operationKey":"create-second-scope","request":create}, (201,))["objectiveId"]
    second_route = "/objectives/" + second_objective + "/trackers"
    second_scope = dict(scope, connectionId="rei-second", incarnation="installation-two")
    second_policy = dict(policy, instructions="IgnoreField", lifecycle="IgnoreField", publication="NoPublication")
    call(second_route + "/commands", {"format":1,"operationKey":"second-bind","request":{"tag":"RunCommand","contents":{"tag":"Bind","contents":["binding-other",second_scope,second_policy]}}}, (202,))
    wait(lambda: call(second_route + "/operations/second-bind"), lambda row: row["state"] == "Finished" and row["failure"] is None)
    assert call(second_route + "/binding-other")["binding"]["preview"]["scope"]["incarnation"] == "installation-two"
    assert binding()["binding"]["preview"]["scope"]["incarnation"] == "installation-one"
    print("PASS identical remote ID in another connection/incarnation has independent binding and source state", flush=True)
    print(json.dumps({"objectiveId": objective, "bindingId": "binding-main", "intentionId": remote, "publicationId": intent["publicationId"], "remoteActionId": action, "actualActionPosts": len(Proxy.posts), "localStatus": call("/objectives/" + objective)["status"], "externalStatus": "abandoned", "deliveryEvidence": "OperatorAttested", "localRevision": call("/objectives/" + objective)["revision"]}), flush=True)
