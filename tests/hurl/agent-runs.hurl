POST {{base_url}}/agents/heartbeat/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"idempotencyKey":"hurl-1","payload":{"task":"hello"}}
HTTP 202
[Captures]
run_id: jsonpath "$.runId"
[Asserts]
header "Location" startsWith "/agents/heartbeat/runs/"
jsonpath "$.status" == "accepted"

POST {{base_url}}/agents/heartbeat/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"idempotencyKey":"hurl-1","payload":{"task":"hello"}}
HTTP 200
[Asserts]
jsonpath "$.runId" == "{{run_id}}"

POST {{base_url}}/agents/heartbeat/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"idempotencyKey":"hurl-1","payload":{"task":"different"}}
HTTP 409
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "idempotency_key_conflict"

POST {{base_url}}/agents/no-such-agent/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"idempotencyKey":"hurl-unknown","payload":{}}
HTTP 404
[Asserts]
jsonpath "$.code" == "agent_not_found"

POST {{base_url}}/agents/disabled-heartbeat/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"idempotencyKey":"hurl-disabled","payload":{}}
HTTP 409
[Asserts]
jsonpath "$.code" == "agent_not_runnable"

POST {{base_url}}/agents/heartbeat/runs
Authorization: Bearer {{token}}
Content-Type: application/json
{"payload":{}}
HTTP 400
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "invalid_body"

GET {{base_url}}/agents/heartbeat/runs/{{run_id}}
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "accepted"
jsonpath "$.acceptedAt" exists
jsonpath "$.sessionId" == null
jsonpath "$.failure" == null

GET {{base_url}}/agents/heartbeat/runs/no-such-run
Authorization: Bearer {{token}}
HTTP 404
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "run_not_found"

GET {{base_url}}/agents/disabled-heartbeat/runs/{{run_id}}
Authorization: Bearer {{token}}
HTTP 404
[Asserts]
jsonpath "$.code" == "run_not_found"

GET {{base_url}}/agents/heartbeat/runs?first=10
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.edges[0].node.runId" == "{{run_id}}"

GET {{base_url}}/agents/heartbeat/runs?first=0
Authorization: Bearer {{token}}
HTTP 400
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "invalid_url"
