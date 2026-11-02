#!/usr/bin/env python3
"""Scripted loopback Responses transport; production parsing and tools execute.

The request/response shapes match the selected Baikai Responses adapter in
mori://shinzui/baikai, baikai-openai/src/Baikai/Provider/OpenAI/Responses/
(artifact-level source URI pending). No public model endpoint is contacted.
"""
import http.server
import json
from pathlib import Path
import sys


def values(value):
    yield value
    if isinstance(value, dict):
        for nested in value.values():
            yield from values(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from values(nested)
    elif isinstance(value, str):
        candidates = [value]
        if "Trigger payload: " in value:
            candidates.append(value.split("Trigger payload: ")[-1])
        for candidate in candidates:
            try:
                parsed, _ = json.JSONDecoder().raw_decode(candidate)
            except (ValueError, TypeError):
                continue
            if parsed != value:
                yield from values(parsed)


def next_action(request):
    inputs = request.get("input", [])
    payloads = [v for v in values(inputs) if isinstance(v, dict) and "scenario" in v]
    payload = payloads[-1] if payloads else {"scenario": "plain"}
    scenario = payload["scenario"]
    calls = []
    for item in inputs:
        if item.get("type") == "function_call" and item.get("name") == "objectives":
            calls.append(json.loads(item["arguments"]))
    replies = [v for v in values(inputs) if isinstance(v, dict) and "objectiveId" in v]
    goal = payload.get("objectiveId") or next((v["objectiveId"] for v in replies), None)
    step = len(calls)
    action = None
    if scenario in ("bootstrap", "denied"):
        if step == 0:
            action = {"tag": "CreateObjective", "request": {
                "title": "Autonomous first objective", "goal": "Reviewed combined artifact",
                "instructions": "Continue through the original accepted binding",
                "criteria": [{"key": "review", "description": "Review the artifact", "kind": "HumanVerifiable", "journeyRequired": False}], "external": []}}
        elif scenario == "bootstrap" and step == 1:
            action = {"tag": "PlanAssignments", "objectiveId": goal, "expectedRevision": 0,
                      "assignments": [{"assignmentId": {"value": "own-work"}, "instructions": "Produce the artifact", "dependencies": [], "state": "Pending"}]}
        elif scenario == "bootstrap" and step == 2:
            action = {"tag": "RecordProgress", "objectiveId": goal, "expectedRevision": 1,
                      "assignmentId": {"value": "own-work"}, "state": "Done", "decisions": [], "assumptions": []}
        elif scenario == "bootstrap" and step == 3:
            action = {"tag": "RecordEvidence", "objectiveId": goal, "expectedRevision": 2,
                      "assignmentId": {"value": "own-work"}, "evidence": {
                          "tag": "Attestation", "key": "review-check", "criterion": "review", "artifact": "bootstrap-artifact",
                          "statement": "Explicit creator review of the fixture artifact", "journey": False}}
    elif scenario in ("worker", "forged") and step == 0:
        action = {"tag": "RecordProgress", "objectiveId": goal, "expectedRevision": payload["expectedRevision"],
                  "assignmentId": {"value": payload["assignmentId"]}, "state": "Done", "decisions": [], "assumptions": []}
    elif scenario == "continue" and step == 0:
        action = {"tag": "InspectObjective", "objectiveId": goal, "after": 0, "limit": 20}
    revisions = [v["revision"] for v in replies if isinstance(v.get("revision"), int)]
    observed = {"scenario": scenario, "step": step, "action": action and action["tag"],
                "objectiveId": goal, "revision": revisions[-1] if revisions else None,
                "denied": "ObjectiveDenied" in json.dumps(inputs)}
    return action, observed, payload


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/responses" or self.headers.get("Authorization") != "Bearer fixture-openai-key":
            self.send_error(403)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= 1048576:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(size))
        action, observed, payload = next_action(request)
        with Path(sys.argv[2]).open("a") as log:
            log.write(json.dumps(observed) + "\n")
        label = f"{observed['scenario']}-{observed['step']}"
        if action:
            output = [{"id": "item-" + label, "type": "function_call", "status": "completed",
                       "call_id": "call-" + label, "name": "objectives", "arguments": json.dumps(action)}]
        else:
            result = {"scenario": observed["scenario"], "artifact": payload.get("artifact", "fixture-artifact"), "value": payload.get("value", "done")}
            output = [{"id": "message-" + label, "type": "message", "status": "completed", "role": "assistant",
                       "content": [{"type": "output_text", "text": json.dumps(result)}]}]
        response = {"id": "response-" + label, "model": request["model"], "status": "completed", "output": output,
                    "usage": {"input_tokens": 1, "output_tokens": 1, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
                              "output_tokens_details": {"reasoning_tokens": 0}}}
        body = ("data: " + json.dumps({"type": "response.completed", "response": response}) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
