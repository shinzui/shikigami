# Opt-in only: the disposable orchestrator has stopped its own PostgreSQL.
GET {{base_url}}/agents/heartbeat/runs/no-such-run
Authorization: Bearer {{token}}
HTTP 503
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "unavailable"
jsonpath "$.retryable" == true

GET {{base_url}}/health/live
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "ok"

GET {{base_url}}/health/ready
HTTP 503
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "failed"
