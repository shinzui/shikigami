#!/usr/bin/env python3
"""Drive disposable serving processes through their real API and queue owners."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

from model import values


REPO, WORK, CONNECTION = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
RUNTIME = WORK / "runtime"
PORTS = json.loads((WORK / "ports.json").read_text())
BINS = {name: (WORK / (name + ".path")).read_text().strip() for name in
        ["shikigami", "shikigami-server", "shikigami-worker", "shikigami-objective-fixture"]}
TOKEN = secrets.token_urlsafe(24)
BASE = f"http://127.0.0.1:{PORTS['http']}"
ACTOR = "agent_01h000000000000000triage"
SUCCESSOR = "agent_01h000000000000000successor"
CALLER = "ir13-caller"
CONFIG = WORK / "config.json"
ENV = {"PATH": os.environ["PATH"], "TMPDIR": str(WORK), "LANG": "C.UTF-8"}
config = {
    "database": {"connection_string": CONNECTION},
    "agents": {"directory": str(RUNTIME / "fixtures/qualification/objectives/agents")},
    "directory": {"mode": "file", "file": {"path": str(RUNTIME / "fixtures/qualification/objectives/directory.json")}, "refresh_interval_seconds": 1},
    "objectives": {"enabled": True, "operator": "ir13-operator", "administration": "AdministerAll", "agentCreation": [ACTOR]},
    "http": {"auth": {"mode": "bearer", "token": TOKEN, "caller": CALLER}},
    "health": {"port": PORTS["health"]}, "worker": {"run_timeout_seconds": 3},
    "behavior": {"provider": "openai-responses", "model": "gpt-6.1-sol", "base_url": f"http://127.0.0.1:{PORTS['model']}/v1",
                 "options": {"max_tokens": 512, "timeout_ms": 5000}},
    "authorization": {"actions": {"mode": "kikan", "kikan_en": {"base_url": f"http://127.0.0.1:{PORTS['oauth']}"},
        "shomei": {"base_url": f"http://127.0.0.1:{PORTS['oauth']}", "client_id": "fixture"},
        "en": {"issuer_public_keys": (WORK / "issuer-public.txt").read_text(), "schema_hashes": "objective-fixture-schema"}, "caller_id": "objective-fixture"}},
    "credentials": {"providers": {"openai": {"api_key": "fixture-openai-key"}},
                    "authorization": {"actions": {"shomei": {"client_secret": "fixture-secret"}}}},
}


def write_config():
    CONFIG.write_text(json.dumps(config))


def sql(statement):
    return subprocess.check_output(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", CONNECTION, "-c", statement], env=ENV, text=True).strip()


def api(method, path, body=None, expected=200, authenticated=True):
    headers = {"Content-Type": "application/json"}
    if authenticated:
        headers["Authorization"] = "Bearer " + TOKEN
    request = urllib.request.Request(BASE + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            code, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        code, raw = error.code, error.read()
    assert code == expected, (method, path, code, raw[:512])
    return json.loads(raw) if raw else None


def wait_for(check, label, timeout=100):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError("timed out: " + label)


def start(name, extra=()):
    log = (WORK / (name + ".log")).open("a")
    process = subprocess.Popen([BINS[name], "--config", str(CONFIG), *extra], cwd=RUNTIME, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    log.close()
    return process


def stop(process, hard=False):
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGKILL if hard else signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def ready(server):
    def check():
        assert server.poll() is None, "server exited during startup"
        try:
            with urllib.request.urlopen(BASE + "/health/ready", timeout=1) as response:
                return response.status == 200
        except (OSError, urllib.error.URLError):
            return False
    wait_for(check, "server readiness", 30)


def request_run(agent, key, payload, association=None):
    body = {"idempotencyKey": key, "payload": payload}
    if association:
        body["objective"] = association
    return api("POST", f"/agents/{agent}/runs", body, 202)["runId"]


def run_done(agent, run, expected="succeeded"):
    def check():
        value = api("GET", f"/agents/{agent}/runs/{run}")
        if value["status"] in ("succeeded", "failed", "dead-lettered", "cancelled"):
            assert value["status"] == expected, value
            return value
        return None
    return wait_for(check, "run " + run, 130)


def inspect(goal):
    return api("GET", "/objectives/" + goal)


def command(goal, key, revision, tag, contents=None, expected=200):
    body = {"tag": tag}
    if contents is not None:
        body["contents"] = contents
    return api("POST", "/objectives/" + goal + "/commands", {"format": 1, "operationKey": key, "expectedRevision": revision, "command": body}, expected)


def operator_command(goal, key, revision, tag, contents):
    path = WORK / "operator-command.json"
    path.write_text(json.dumps({"tag": tag, "contents": contents}))
    value = subprocess.check_output([BINS["shikigami"], "--config", str(CONFIG), "objectives", "command", goal,
        "--operation-key", key, "--expected-revision", str(revision), "--file", str(path), "--json"], cwd=RUNTIME, env=ENV, text=True)
    return json.loads(value)


def observations():
    path = WORK / "model-observations.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def conversation(message, payload):
    subprocess.check_call([BINS["shikigami-objective-fixture"], "enqueue-conversation", str(CONFIG), "ir13-conversation", message, json.dumps(payload)], cwd=RUNTIME, env=ENV)
    # A completed turn is an owning journal fact. Reply transport permission is
    # independent of objective access and remains denied by this fixture's C11.
    query = "SELECT count(*) FROM keiro.keiro_workflow_steps WHERE workflow_name='shikigami.danwa-conversation' AND step_name='turn-result'"
    wanted = 1 if message == "first" else 2
    wait_for(lambda: int(sql(query)) >= wanted, "recorded conversation turn")


def attest(goal, key, assignment, criterion, artifact, journey):
    evidence = {"tag": "Attestation", "key": key, "criterion": criterion, "artifact": artifact,
                "statement": "Explicit authorized review of the retained fixture artifacts", "journey": journey}
    return command(goal, "record-" + key, inspect(goal)["revision"], "RecordEvidence", [{"value": assignment}, evidence])


def propose(goal, key, artifact, checks):
    current = inspect(goal)
    proposal = {"objectiveRevision": current["revision"], "instructionsRevision": current["instructionsRevision"],
                "criteriaRevision": current["criteriaRevision"], "artifacts": [artifact], "checks": checks, "limitations": []}
    return command(goal, key, current["revision"], "ProposeCompletion", proposal)


server = worker = gate = None
write_config()
try:
    server = start("shikigami-server", ["--host", "127.0.0.1", "--port", str(PORTS["http"])])
    ready(server)
    api("GET", "/objectives", expected=401, authenticated=False)

    # Hold only the first creation tool's protected outcome. The goal command
    # commits on its own owner before this transaction reaches the gate.
    guard = 83017001
    gate_env = dict(ENV, PGAPPNAME="ir13-ack-gate")
    gate = subprocess.Popen(["psql", "-XqAt", CONNECTION, "-c", f"SELECT pg_advisory_lock({guard}); SELECT pg_sleep(180)"], env=gate_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(lambda: sql(f"SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid={guard} AND granted") == "1", "owned acknowledgement gate")
    sql(f"CREATE FUNCTION shikigami.hold_objective_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.body->>'kind'='operation-outcome' AND NEW.body::text LIKE '%ObjectiveCreated%' THEN PERFORM pg_advisory_xact_lock({guard}); END IF; RETURN NEW; END $$; CREATE TRIGGER hold_objective_ack BEFORE INSERT ON shikigami.execution_payloads FOR EACH ROW EXECUTE FUNCTION shikigami.hold_objective_ack()")
    bootstrap = request_run("triage", "autonomous-create", {"scenario": "bootstrap"})
    worker = start("shikigami-worker")
    wait_for(lambda: sql(f"SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid={guard} AND NOT granted") == "1", "committed creation before tool outcome")
    original = json.loads(sql("SELECT receipt FROM shikigami.objective_origins WHERE origin->>'tag'='ExecutionOrigin'"))
    autonomous = original["objectiveId"]
    before = sql("SELECT md5(body::text) FROM shikigami.execution_payloads WHERE body->>'kind'='snapshot' ORDER BY execution_id")
    stop(worker, hard=True)
    worker = None
    sql(f"SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND objid={guard} AND NOT granted")
    sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='ir13-ack-gate'")
    stop(gate)
    gate = None
    sql("DROP TRIGGER hold_objective_ack ON shikigami.execution_payloads")
    stop(server)
    server = None
    config["objectives"]["agentCreation"] = []
    write_config()
    server = start("shikigami-server", ["--host", "127.0.0.1", "--port", str(PORTS["http"])])
    ready(server)
    worker = start("shikigami-worker")
    run_done("triage", bootstrap)
    replayed = json.loads(sql("SELECT receipt FROM shikigami.objective_origins WHERE origin->>'tag'='ExecutionOrigin'"))
    assert original == replayed
    assert sql("SELECT count(*) FROM shikigami.objectives") == "1"
    assert before == sql("SELECT md5(body::text) FROM shikigami.execution_payloads WHERE body->>'kind'='snapshot' ORDER BY execution_id")
    assert sql("SELECT coalesce(sum((state->>'pendingReceipts')::integer),0) FROM shikigami.executions") == "0"
    operator_command(autonomous, "grant-public-continuity", 3, "GrantMember", [{"tag": "VerifiedCaller", "contents": CALLER}, ["Coordinator", "Reader", "Completer"]])
    assert inspect(autonomous)["revision"] == 4
    print(f"PASS autonomous creation/restart objective={autonomous} receipt={original['operationId']}@{original['payloadDigest']} replay-identical=true revision=4 status=Open", flush=True)

    # Both recall channels are unavailable. Session/turn ownership remains live.
    sql("ALTER TABLE kioku.memories RENAME TO memories_disabled_fixture")
    later = request_run("triage", "later-associated", {"scenario": "continue", "objectiveId": autonomous}, {"objectiveId": autonomous, "assignmentId": {"value": "own-work"}})
    run_done("triage", later)
    assert any(v["scenario"] == "continue" and v["revision"] == 4 for v in observations())
    assert sql("SELECT count(*) FROM keiro.keiro_workflow_steps WHERE step_name='recall' AND result <> '[]'::jsonb") == "0"
    conversation("first", {"scenario": "plain"})
    command(autonomous, "bind-conversation", 4, "BindConversation", "ir13-conversation")
    conversation("second", {"scenario": "continue", "objectiveId": autonomous})
    assert any(v["scenario"] == "continue" and v["revision"] == 5 for v in observations())
    print("PASS associated later run and explicitly bound conversation read current progress with learning memory unavailable", flush=True)

    # Separate authenticated API surface: two finite workers, no implicit root.
    create_request = json.loads((REPO / "fixtures/qualification/objectives/create.json").read_text())
    envelope = {"format": 1, "operationKey": "api-finite-create", "request": create_request}
    created = api("POST", "/objectives", envelope, 201)
    assert api("POST", "/objectives", envelope) == created
    goal = created["objectiveId"]
    graph = [{"assignmentId": {"value": key}, "instructions": "Produce retained fixture component", "dependencies": [],
              "owner": {"kind": "verified", "principalId": actor}, "state": "Pending", "sessionId": None, "rootId": None, "cutoff": None}
             for key, actor in [("a", ACTOR), ("b", SUCCESSOR)]]
    command(goal, "plan-api-workers", 0, "SetAssignments", graph)
    for key, actor in [("a", ACTOR), ("b", SUCCESSOR)]:
        command(goal, "grant-worker-" + key, inspect(goal)["revision"], "GrantMember", [{"tag": "RecordedAgent", "contents": {"kind": "verified", "principalId": actor}}, ["Worker", "Reader"]])
    components = []
    for key, agent, value in [("a", "triage", "component-a"), ("b", "successor", "component-b")]:
        run = request_run(agent, "api-worker-" + key, {"scenario": "worker", "objectiveId": goal, "assignmentId": key,
                          "expectedRevision": inspect(goal)["revision"], "artifact": "artifact-" + key, "value": value}, {"objectiveId": goal, "assignmentId": {"value": key}})
        run_done(agent, run)
        # Read only this completed execution's retained model outcomes in the
        # disposable owner database. Never manufacture a result from its input.
        outcomes = json.loads(sql("SELECT json_agg(p.body) FROM shikigami.execution_payloads p WHERE p.body->>'kind'='operation-outcome' AND p.execution_id IN (SELECT execution_id FROM shikigami.execution_payloads WHERE body->>'kind'='snapshot' AND body->'content'->>'runId'='" + run + "')"))
        results = [item for item in values(outcomes) if isinstance(item, dict) and item.get("scenario") == "worker" and "artifact" in item and "value" in item]
        assert results and all(item == results[0] for item in results)
        result = results[0]
        assert result["artifact"] == "artifact-" + key and result["value"] == value
        components.append(result["artifact"] + ":" + result["value"])
    assert [a["state"] for a in inspect(goal)["assignments"]] == ["Done", "Done"]
    assert inspect(goal)["status"] == "Open"
    command(goal, "stale-progress", 1, "SetNextAction", ["stale"], expected=409)

    # The combined artifact is a deterministic review commitment over both
    # completed fixture components. Explicit completer attestations carry the
    # review result; model/worker success never supplies a passing criterion.
    artifact = "combined:" + hashlib.sha256("|".join(components).encode()).hexdigest()
    failed_components = list(reversed(components))
    # The fixture journey presents component a before b. Both workers are
    # green, but the first integration reverses them and fails that review.
    def journey_passes(parts):
        return parts == ["artifact-a:component-a", "artifact-b:component-b"]
    assert not journey_passes(failed_components)
    failed_artifact = "combined:" + hashlib.sha256("|".join(failed_components).encode()).hexdigest()
    attest(goal, "combined-old", "a", "combined", failed_artifact, False)
    propose(goal, "missing-journey-proposal", failed_artifact, ["combined-old"])
    command(goal, "missing-journey-accept", inspect(goal)["revision"], "AcceptCompletion", expected=400)
    assert inspect(goal)["status"] == "Open"
    print("PASS both workers succeeded; failing integrated journey leaves objective Open", flush=True)
    criteria = create_request["criteria"]
    criteria[1]["description"] = "The current integrated journey passes the revised review"
    command(goal, "revise-review-criteria", inspect(goal)["revision"], "ReviseCriteria", criteria)
    command(goal, "stale-criteria-accept", inspect(goal)["revision"], "AcceptCompletion", expected=409)
    attest(goal, "combined-current", "a", "combined", artifact, False)
    assert journey_passes(components)
    attest(goal, "journey-current", "b", "journey", artifact, True)
    propose(goal, "current-combined-proposal", artifact, ["combined-current", "journey-current"])
    expected_revision = inspect(goal)["revision"]
    accepted = command(goal, "explicit-integrated-accept", expected_revision, "AcceptCompletion")
    assert command(goal, "explicit-integrated-accept", expected_revision, "AcceptCompletion") == accepted
    final = inspect(goal)
    assert final["status"] == "Completed"
    history = api("GET", "/objectives/" + goal + "/history?limit=100")["items"]
    assert sum(item["command"] == "AcceptCompletion" for item in history) == 1, "expected exactly one accepted completion in immutable history"
    assert all(item["actor"]["identity"] == CALLER for item in history if item["command"] == "AcceptCompletion")
    print(f"PASS integrated explicit acceptance objective={goal} revision={final['revision']} receipt={accepted['operationId']}@{accepted['payloadDigest']} status=Completed", flush=True)

    forged = request_run("triage", "forged-selector", {"scenario": "forged", "objectiveId": goal, "assignmentId": "a", "expectedRevision": final["revision"]}, {"objectiveId": autonomous, "assignmentId": {"value": "own-work"}})
    run_done("triage", forged)
    assert any(value["scenario"] == "forged" and value["denied"] for value in observations())
    assert inspect(goal) == final

    # A denied creator has no offered objective tool and creates no goal.
    denied = request_run("successor", "denied-creator", {"scenario": "denied"})
    run_done("successor", denied, "failed")
    assert sql("SELECT count(*) FROM shikigami.objectives") == "2"
    stop(server)
    server = None
    config["http"]["auth"]["caller"] = "ir13-intruder"
    write_config()
    server = start("shikigami-server", ["--host", "127.0.0.1", "--port", str(PORTS["http"])])
    ready(server)
    api("GET", "/objectives/" + autonomous, expected=404)
    command(autonomous, "intruder-mutation", 5, "SetNextAction", ["forbidden"], expected=403)
    assert api("GET", "/objectives")["items"] == []
    print("PASS denied creator, forged accessible selector and authenticated non-member refused; stale public update conflicted", flush=True)
finally:
    if gate is not None:
        sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='ir13-ack-gate'")
    stop(gate)
    stop(worker)
    stop(server)
