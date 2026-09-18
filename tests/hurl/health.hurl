GET {{base_url}}/health/live
HTTP 200
[Asserts]
header "Content-Type" startsWith "application/json"
jsonpath "$.status" == "ok"
jsonpath "$.check" == "all"

GET {{base_url}}/health/ready
HTTP 200
[Asserts]
header "Content-Type" startsWith "application/json"
jsonpath "$.status" == "ok"
jsonpath "$.check" == "all"
