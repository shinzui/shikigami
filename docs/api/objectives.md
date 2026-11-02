# Objective HTTP contract

The authenticated `/objectives` vertical uses the same command owner as
`shikigami objectives`. Enable it through `SHIKIGAMI_OBJECTIVES` with
`{"enabled":true}` and configure bearer authentication. Anonymous development
access never becomes an objective principal. Disabled tracking returns 503.

Create with `POST /objectives`:

```json
{
  "format": 1,
  "operationKey": "delivery-create",
  "request": {
    "title": "Deliver the combined artifact",
    "goal": "A reviewed working result",
    "instructions": "Protected working instructions",
    "criteria": [
      {"key": "review", "description": "Review the combined artifact", "kind": "HumanVerifiable", "journeyRequired": false}
    ],
    "external": []
  }
}
```

Creation returns 201 and a receipt containing `objectiveId`, `operationId`,
`fingerprint`, `revision` and `payloadDigest`. Identical retries return that
receipt with 200. Creation is scoped to the authenticated creator. Changed input
under an accepted operation key returns 409.

Submit `POST /objectives/OBJECTIVE/commands`:

```json
{
  "format": 1,
  "operationKey": "delivery-next",
  "expectedRevision": 0,
  "command": {"tag": "SetNextAction", "contents": ["Review the combined artifact"]}
}
```

Only the closed public command sum appears in the generated OpenAPI schema.
Unknown versions, missing versions, internal command tags and extra envelope
fields are refused. Authority comes from the bearer verifier and current
membership, independently of the document. An accepted command returns 200;
retries must retain the exact expected revision and bytes. A stale fresh command
or changed key reuse returns 409. Invalid documents return 400, insufficient
command authority returns 403 and unavailable authority returns 503. Wire bodies,
including whitespace and chunked data, are limited to 1 MiB; excess returns 413.

`GET /objectives?after=OBJECTIVE&limit=20` pages the caller's current objectives in
identifier order. Follow `next` until it is null. `GET /objectives/OBJECTIVE`
returns public metadata: goal, criteria, assignment progress, evidence references,
reported-result commitments and next actions. It excludes instructions and result
bodies. Collection fields share `after=OFFSET&limit=20`; follow `next` only while
the returned objective revision stays unchanged, restarting if it changes.
`GET /objectives/OBJECTIVE/history?after=REVISION&limit=20` pages accepted receipts
in revision order with their recorded actor and command. A rejected operation
adds no mutation to that history. Every page defaults to 20 and caps at 100.
Missing and inaccessible objectives both return 404 for inspection and history;
revocation takes effect on fresh operations and receipt recovery.

`BindConversation` uses the real indexed memory session and a matching recorded
objective member. Supplying a conversation key cannot invent that participant.
Run requests can carry the optional trusted objective/assignment selector; it
commits with acceptance and queue send. Objective-shaped trigger payload remains
ordinary text and grants no association. Existing unassociated requests keep their
original codecs and fingerprints.

Protected evidence stays with its original owner; metadata references confer no
read or mutation permission. Worker result success records an observation. It
cannot replace verifier-backed automatic checks or explicit integrated acceptance.
