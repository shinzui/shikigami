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
