GET {{base_url}}/agents
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 2
jsonpath "$.edges[0].node.name" == "disabled-heartbeat"
jsonpath "$.edges[1].node.name" == "heartbeat"
jsonpath "$.pageInfo.hasNextPage" == false

GET {{base_url}}/agents?first=1
HTTP 200
[Asserts]
jsonpath "$.edges" count == 1
jsonpath "$.pageInfo.hasNextPage" == true

GET {{base_url}}/agents/heartbeat
HTTP 200
[Asserts]
jsonpath "$.runnable" == true
jsonpath "$.lifecycle" == "unverified"

GET {{base_url}}/agents/disabled-heartbeat
HTTP 200
[Asserts]
jsonpath "$.enabled" == false
jsonpath "$.runnable" == false

GET {{base_url}}/agents/no-such-agent
HTTP 404
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "agent_not_found"
jsonpath "$.retryable" == false

GET {{base_url}}/agents?first=0
HTTP 400
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "invalid_url"

GET {{base_url}}/agents?first=-1
HTTP 400
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "invalid_url"
