GET {{base_url}}/agents
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 2
jsonpath "$.edges[0].node.name" == "disabled-heartbeat"
jsonpath "$.edges[1].node.name" == "heartbeat"
jsonpath "$.pageInfo.hasNextPage" == false

GET {{base_url}}/agents?first=1
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 1
jsonpath "$.pageInfo.hasNextPage" == true

GET {{base_url}}/agents/heartbeat
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.runnable" == true
jsonpath "$.lifecycle" == "unverified"

GET {{base_url}}/agents/disabled-heartbeat
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.enabled" == false
jsonpath "$.runnable" == false

GET {{base_url}}/agents/no-such-agent
Authorization: Bearer {{token}}
HTTP 404
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "agent_not_found"
jsonpath "$.retryable" == false

GET {{base_url}}/agents?first=0
Authorization: Bearer {{token}}
HTTP 400
[Asserts]
header "Content-Type" startsWith "application/json"
jsonpath "$.code" == "invalid_page_size"

GET {{base_url}}/agents?first=-1
Authorization: Bearer {{token}}
HTTP 400
[Asserts]
header "Content-Type" startsWith "application/json"
jsonpath "$.code" == "negative_page_size"

GET {{base_url}}/agents?first=1&last=1
Authorization: Bearer {{token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.code" == "mixed_pagination_directions"
jsonpath "$.retryable" == false
