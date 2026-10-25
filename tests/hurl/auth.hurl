GET {{base_url}}/agents
HTTP 401
[Asserts]
header "Content-Type" == "application/problem+json"
header "WWW-Authenticate" == "Bearer realm=\"shikigami\""
jsonpath "$.code" == "unauthorized"
jsonpath "$.detail" == "A valid bearer token is required."
jsonpath "$.retryable" == false

GET {{base_url}}/agents
Authorization: Bearer wrong
HTTP 401
[Asserts]
jsonpath "$.detail" == "A valid bearer token is required."
jsonpath "$.code" == "unauthorized"

GET {{base_url}}/agents
Authorization: Bearer {{token}}
HTTP 200

GET {{base_url}}/health/live
HTTP 200
