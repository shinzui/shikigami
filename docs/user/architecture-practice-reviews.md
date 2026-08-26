# Architecture-practice reviews

The checked-in `architecture-practice-router` delegates a version-1 review trigger to an
authorized specialist. The OpenTelemetry specialist reads only revision-pinned evidence, recalls
prior adjudication, validates one advisory verdict, records it as review memory, and enqueues Kawa
history. It requests Kizashi attention only when the verdict needs action.

The review path has no workspace writer, patch, merge, approval-gate, or repository-block
capability. A verdict is evidence and advice; it cannot stop a build or change source code.

> **Live-evidence status:** the deployed reader remains fail-closed until
> `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` supplies the released content-plane
> seam. The current production composition records structured `content-plane-unavailable`
> problems and returns `unresolved`; it never falls back to ambient Git or the worker workspace.

## Trigger a review

Producers send the raw trigger to the router. They do not name a specialist or candidate:

```json
{
  "schemaVersion": 1,
  "triggerKind": "target-change",
  "idempotencyKey": "mori:practice-review:example:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "target": {"name": "shinzui/example-service", "repository": "repo_target"},
  "targetRange": {
    "changeKind": "modified",
    "before": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "changedDecisionPaths": ["docs/adr/0008-adopt-opentelemetry.md"],
  "adoptions": [{
    "practice": "opentelemetry",
    "references": [{
      "project": {"name": "shinzui/haskell-jitsurei", "repository": "repo_practice"},
      "provenance": {"repository": "repo_practice", "revision": "cccccccccccccccccccccccccccccccccccccccc"},
      "documentIds": ["api-opentelemetry-integration"]
    }],
    "claimedApplicability": {
      "projects": [{"name": "shinzui/example-service", "repository": "repo_target"}],
      "paths": ["docs/adr"], "dependencies": [], "practices": ["opentelemetry"]
    },
    "mode": "advisory",
    "owners": {
      "targetOwner": "team-example-service",
      "practiceOwner": "team-haskell-platform",
      "triageOwner": "architecture-council"
    },
    "upstreamProjects": []
  }]
}
```

The five classifications are:

| Classification | Meaning | Attention |
| --- | --- | --- |
| `consistent` | Target and registered practice agree. | None |
| `target-suspect` | The target decision may need correction. | Target owner |
| `reference-suspect` | The registered practice may be stale or too broad. | Practice owner |
| `legitimate-exception` | The difference is intentional and scoped. | Exception approver only when approval is still required |
| `unresolved` | Required pinned evidence was unavailable or insufficient. | Triage owner |

Every completed review has one provisional memory and one Kawa
`practice-review.completed` activity. Kawa context refs point to the cited Mori projects and the
logical `activity://practice-review/<review-id>` identity. A reference-change trigger carries
`priorReviewId` and a pinned `referenceChange`; the new verdict links the earlier review without
rewriting its history.

## Resolve a review

A resolution is a separate, directly addressed command. The ingress boundary authenticates a
human or approved artifact, checks that subject against `resolution.resolver`, and records a
version-1 authorization receipt. Raw credentials and tokens never enter the durable envelope.

```json
{
  "schemaVersion": 1,
  "resolution": {
    "schemaVersion": 1,
    "resolutionId": "<deterministic UUIDv5>",
    "idempotencyKey": "resolution-command-accepted",
    "reviewId": "<review UUID>",
    "outcome": "accepted",
    "resolver": "architecture-council",
    "reason": "The cited contradiction is confirmed.",
    "resolvedAt": "2026-08-26T20:00:00Z",
    "resultingApplicability": {
      "projects": [{"name": "shinzui/example-service", "repository": "repo_target"}],
      "paths": ["docs/adr"], "dependencies": [], "practices": ["opentelemetry"]
    },
    "supersedingReviewId": null
  },
  "authorization": {
    "authorizationId": "<receipt UUIDv5>",
    "authorityKind": "human",
    "verifiedSubject": "architecture-council",
    "sourceReference": "activity://approval/<approval-id>",
    "authorizedAt": "2026-08-26T20:00:00Z"
  }
}
```

The outcomes are `accepted`, `rejected`, `narrowed`, and `superseded`. Accepted and narrowed
commands require resulting applicability; rejected commands carry neither applicability nor a
superseding review; superseded commands name a different review. A bare resolution, a
resolver/subject mismatch, a noncanonical authorization source, or an altered receipt is refused
before memory changes. A Kizashi acknowledgement does not resolve a review.

## Configure attention and grants

The reviewer declaration pins sanctioned execution profile `sanctioned-review` version `1`.
Provision that immutable active profile in the deployment profile store before enabling the agent;
an absent, mutable, expired, withdrawn, digest-mismatched, or provider-incompatible profile is
refused before the review session or any content/model operation starts.

Map semantic owner principals to concrete Kizashi recipients. Keys containing multiple owners are
sorted and joined with `+`; duplicate canonical keys and values without the `recipient_` prefix
make configuration fail at boot.

```yaml
practice_review:
  attention_recipients: >-
    architecture-council=recipient_triage,
    team-example-service=recipient_target,
    team-haskell-platform=recipient_practice
```

The equivalent environment variable is
`SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS`. An empty or missing mapping is deliberately
fail-closed for actionable reviews; the deployment-wide Kizashi fallback is not used.

Sync the declaration, grant both Flow emissions to the reviewer's recorded principal, and verify:

```bash
cabal run shikigami -- agents sync
cabal run shikigami -- grants grant opentelemetry-practice-reviewer KawaDigest --by operator
cabal run shikigami -- grants grant opentelemetry-practice-reviewer KizashiSignal --by operator
cabal run shikigami -- grants list
```

The reviewer declaration remains sink-free. These grants authorize explicit Flow emissions; they
do not add generic post-behavior sinks.

## Inspect and recover delivery

Each distinct review retains its own Kawa history. Equivalent actionable disputes share one
semantic attention reservation and one Kizashi delivery identity. Inspect the reservation and its
authoritative receipt together:

```sql
SELECT
  a.attention_key,
  a.originating_review_id,
  a.recipient,
  d.status,
  d.detail,
  d.updated_at
FROM shikigami.practice_review_attention AS a
JOIN shikigami.sink_deliveries AS d
  ON d.outbox_message_id = a.outbox_message_id
ORDER BY a.created_at DESC;
```

`sink_deliveries.status` is the only delivery truth. `detail` holds the downstream Kizashi id after
success. Do not delete or release a semantic reservation when delivery is `failed`, `dead`, or
`unknown`; inspect the existing outbox/receipt and use the normal outbox recovery commands. Sending
an equivalent review will link another review id to the same reservation, not create a replacement
signal.

```bash
cabal run shikigami -- outbox show <outbox-message-id>
cabal run shikigami -- outbox requeue-stuck
cabal run shikigami -- outbox maintenance-pass
```
