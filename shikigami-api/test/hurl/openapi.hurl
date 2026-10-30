GET {{base_url}}/openapi
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.openapi" == "3.1.0"
jsonpath "$.paths['/agents']" exists
jsonpath "$.paths['/agents/{agentName}/runs/{runId}'].get.responses['500'].content['application/problem+json']" exists
jsonpath "$.paths['/agents'].get.responses['400'].content['application/json']" exists
