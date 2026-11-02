POST {{base_url}}/objectives
Authorization: Bearer {{token}}
Content-Type: application/json
{"format":1,"operationKey":"hurl-objective","request":{"title":"Deliver an artifact","goal":"A reviewed artifact","instructions":"Protected working instructions","criteria":[{"key":"review","description":"Review the artifact","kind":"HumanVerifiable","journeyRequired":false}],"external":[]}}
HTTP 201
[Captures]
objective_id: jsonpath "$.objectiveId"
create_digest: jsonpath "$.payloadDigest"
[Asserts]
jsonpath "$.revision" == 0

POST {{base_url}}/objectives
Authorization: Bearer {{token}}
Content-Type: application/json
{"format":1,"operationKey":"hurl-objective","request":{"title":"Deliver an artifact","goal":"A reviewed artifact","instructions":"Protected working instructions","criteria":[{"key":"review","description":"Review the artifact","kind":"HumanVerifiable","journeyRequired":false}],"external":[]}}
HTTP 200
[Asserts]
jsonpath "$.objectiveId" == "{{objective_id}}"
jsonpath "$.payloadDigest" == "{{create_digest}}"

GET {{base_url}}/objectives/{{objective_id}}
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.status" == "Open"
jsonpath "$.instructions" not exists
jsonpath "$.criteria[0].key" == "review"

POST {{base_url}}/objectives/{{objective_id}}/commands
Authorization: Bearer {{token}}
Content-Type: application/json
{"format":1,"operationKey":"hurl-next","expectedRevision":0,"command":{"tag":"SetNextAction","contents":["Review combined artifact"]}}
HTTP 200
[Asserts]
jsonpath "$.revision" == 1

GET {{base_url}}/objectives/{{objective_id}}/history?limit=1
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.items[0].receipt.revision" == 0
jsonpath "$.items[0].actor.kind" == "caller"
jsonpath "$.next" == 0

GET {{base_url}}/objectives/{{objective_id}}/history?after=0&limit=1
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.items[0].receipt.revision" == 1
jsonpath "$.next" == null

POST {{base_url}}/objectives/{{objective_id}}/commands
Authorization: Bearer {{token}}
Content-Type: application/json
{"format":1,"operationKey":"hurl-stale","expectedRevision":0,"command":{"tag":"SetNextAction","contents":[]}}
HTTP 409
[Asserts]
jsonpath "$.code" == "idempotency_key_conflict"

GET {{base_url}}/objectives?limit=1
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.items[0].objectiveId" == "{{objective_id}}"
