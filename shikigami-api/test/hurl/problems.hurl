GET {{base_url}}/no-such-thing
HTTP 404
[Asserts]
header "Content-Type" startsWith "application/problem+json"
jsonpath "$.type" == "about:blank"
jsonpath "$.status" == 404
jsonpath "$.code" == "not_found"
jsonpath "$.retryable" == false

POST {{base_url}}/health/live
HTTP 405
[Asserts]
header "Content-Type" startsWith "application/problem+json"
jsonpath "$.type" == "about:blank"
jsonpath "$.status" == 405
jsonpath "$.code" == "method_not_allowed"
jsonpath "$.retryable" == false
