---
type: "Reference"
title: "Kikan service outputs and sink grants"
description: "Look up Kikan output declarations, delivery behavior, and permission requirements."
docId: "DOC-9"
tags: ["sinks", "permissions"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Kikan service outputs and sink grants

Use the Kikan distribution when the result of a run should reach Kawa,
Kizashi, Rei, Danwa or Kanmon. Declare the destination in `outputs` using
the binding's [Dhall helpers](../../packs/kikan-shikigami-binding/dhall/Outputs.dhall).
Delivery checks lifecycle, the grant for the output kind and authorization
for the exact target. For a local report or to understand an empty `outputs`
list, see [where a run's result goes](outputs.md).

```dhall
let A = ./schema/Agent.dhall

let K = ./packs/kikan-shikigami-binding/dhall/Outputs.dhall

in  A.Agent::{
    , name = "heartbeat"
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , behavior = A.Behavior.ShikumiProgram { task = "noop-summary", preferEnrichment = False, grounding = None Text }
    , outputs = [ K.kawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
```

| Registered kind | Helper | Delivery |
| --- | --- | --- |
| `kawa.digest` | `K.kawaDigest` | Write an activity to the Kawa ingest doorway. |
| `kizashi.signal` | `K.kizashiSignal` | Raise a signal for the resolved recipient. |
| `rei.action` | `K.reiAction` | Record an action against a specified Rei intention. |
| `danwa.conversation` | `K.danwaConversation` | Open a thread or reply in an existing one. |
| `channel.egress` | `K.channelEgress` | Send an approved channel action through Kanmon. |

## KawaDigest — write back to the stream

```dhall
K.kawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" }
```

Builds a nine-field **Activity Envelope** from the behavior's output and POSTs it to kawa's
ingest doorway. The runtime fills the envelope: `source = "shinzui/shikigami"`,
`actor.kind = "agent"` (so the rest of the system can tell agent-produced memory from human
memory), `subject.type` and `verb` from this config, and `payload` from the behavior's
output. It mints the envelope's UUIDv7 `activity_id` itself and derives an idempotency key so
re-delivery is a no-op.

This is the sink that **closes the living loop**: a digest written here reappears on
`activity.v1` and can trigger a second agent. See **[The Living Loop](./living-loop.md)**.

A Flow payload may provide a top-level `context_refs` array. The Kawa adapter accepts only Kawa's
closed schemes, bounds the array, deduplicates exact refs, and rejects malformed refs permanently
before HTTP. Architecture-practice reviews use `mori://` project refs and one
`activity://practice-review/<review-id>` logical ref; see
[Architecture-practice reviews](./architecture-practice-reviews.md).

## KizashiSignal — raise awareness

```dhall
K.kizashiSignal
  K.KizashiSignal::{
  , source = "shinzui/shikigami"
  , signalType = K.SignalType.TaskCandidate
  , priority = K.Priority.Normal
  , importance = 45
  , recipientFrom = K.RecipientFrom.SubjectOwner
  , defaultRecipient = Some "person_owner"
  , intentTemplate = "triage this ticket"
  , extraContextTags = [ "verb:ticket.received", "subject:ticket" ]
  }
```

Raises a `shinzui/kizashi` signal — the awareness primitive. Fields:

| Field | Meaning |
| --- | --- |
| `source` | the raiser's own identity — `"shinzui/shikigami"` for this runtime |
| `signalType` | one of `Notification \| Alert \| Reminder \| TaskCandidate \| DigestItem \| AgentRequest` |
| `priority` | one of `Low \| Normal \| High \| Urgent` |
| `importance` | a `Natural` (0–100 band; e.g. 40–69 for reminders, 70–89 for alerts) |
| `recipientFrom` | how to route — `SubjectOwner \| AreaOwner \| Actor` |
| `defaultRecipient` | fallback recipient when routing can't resolve an owner |
| `intentTemplate` | the signal's human intent line (may interpolate `{subject.title}`, `{params.…}`) |
| `extraContextTags` | extra tags; the runtime **always** also adds `activity://<activity_id>` (the back-reference linking awareness to memory) |

The runtime fills `actor` (the audit string of who *caused* the triggering activity) and the
resolved `recipient` from the trigger context.

## ReiAction — the rei handoff bridge

```dhall
K.reiAction { intentionId = "intention_01k…", note = "delegation overdue" }
```

The explicit, designed bridge from a **shikigami** (system) agent into **rei**'s
(intention-bound) context. When a finding concerns a *specific intention*, this sink records
an action **against that target intention** through `rei`'s **command API** under the agent's
`shomei` identity — **never** by touching `rei`'s store directly. `intentionId` names the
target intention; `note` is the action's content.

When `sinks.rei.base_url` is configured, the runtime POSTs the action to Rei's integration
endpoint. With no endpoint, it reports a retryable non-delivery instead of claiming success.
The contract remains an API handoff, never direct access to Rei's store.

## DanwaConversation — open/attach a conversation

```dhall
K.danwaConversation { topic = "incident-42" }
```

Opens or attaches a `shinzui/danwa` conversation on the given topic. An addressed
conversation reply posts into its existing thread; an ordinary run starts a thread, joins the
configured agent participant, and posts the behavior output. Delivery receipts retain a
started conversation across retries. A fresh conversation requires a non-empty topic because
that stable value is the authorization target available before any Danwa IO.

## ChannelEgress — act through Kanmon

```dhall
K.channelEgress
  K.ChannelEgress::{ channel = "intercom", action = "reply_to_conversation" }
```

Sends an approved channel action to Kanmon at
`POST /channels/intercom/actions/reply_to_conversation`. Shikigami resolves the destination
once, before durable enqueue, using the first non-empty value in this order:

1. the declaration's `conversationKey`;
2. a top-level `conversation_key` string in the behavior output; or
3. the triggering activity's `subject.id`.

If none exists, publication fails permanently without making a request. The request content
comes from the first non-empty top-level `reply`, `content`, or `summary` string, then falls
back to compact JSON. The stable `agent:runId:ordinal` sink identity becomes Kanmon's
idempotency key, and the triggering activity id is carried separately. The full activity is
not copied into the outbox row.

The workflow journals only `Enqueued`. Delivery becomes true when Kanmon returns its
`activity_id`; that id is stored in the delivery receipt. A delivered receipt suppresses a
later local re-send, while Kanmon's idempotency store covers a crash after it accepted the
action but before Shikigami recorded the acknowledgement.

Grant the sink independently of declaring it:

```bash
cabal run shikigami -- grants grant channel-reply channel.egress --by operator
```

Shikigami authenticates with `credentials.sinks.kanmon.token` and never receives the
Intercom or Zendesk provider credential. Kanmon owns destination authorization. HTTP 408,
425, 429, 5xx, transport failures, and unavailable credential sources remain retryable;
other 4xx responses, invalid routes or requests, oversized bodies, and malformed success
responses become terminal delivery failures. Diagnostics and logs never contain the token,
request content, conversation key, or raw response body.

## The permission gate

**Every sink dispatch is gated by two permission checks** tied to the agent's identity. If a
sink is **denied**, it is **logged and skipped** — the run still completes, and the session
records the denial. A denied sink never crashes the agent.

The check consults `shikigami.sink_grants` through the database-backed grant store. Operators
use `shikigami grants grant`, `grants revoke`, and `grants list`; production does not use the
compiled static fixture. The runtime checks at enqueue and again at publication, so a
revocation after enqueue still prevents the external effect. A denial is journaled as
`DeniedOutcome` and creates no outbox row or delivery receipt.

After that C11 sink-kind check, Kikan-En C13 authorizes the exact fully resolved target: Kawa
source, Kizashi recipient, Rei intention, Danwa thread/topic, or channel plus conversation key.
It is checked before enqueue and checked again before publication; no proof is stored in the
journal or outbox. The adapter validates the resolved target for its service before it requests authorization.
An authorization-service outage or rejected proof is reported as `AuthorizationFailed`, creates
no enqueue row, and performs no delivery IO. See
[Per-action authorization operations](../operations/action-authorization.md).

This means you can **declare** sinks freely and control which ones an agent is actually
permitted to fire through the grant layer — declaration and authorization are separate
concerns.

Flow-owned emissions also pass these checks. A Flow can enqueue a specific
output at a lifecycle step. Its returned result is separately subject to the
composition's [default output](outputs.md).
