---
type: "Reference"
title: "Sinks — what an agent produces"
description: "Look up sink declarations, delivery behavior, and permission requirements."
docId: "DOC-9"
tags: ["sinks", "permissions"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Sinks — *what* an agent produces

Agents are **producers, not just reactors**. A sink is an outward action the agent takes with
its behavior's output. An agent declares zero or more sinks; each is considered after the
behavior runs and is **gated by lifecycle, sink-kind permission, and exact action
authorization**. Default `authorization.actions.mode=disabled` allows no protected
external action, including delivery to a stub.

An agent lists them in `outputs`. Each output is a registered kind and its JSON
configuration; the Kikan binding owns the five kinds below and a typed Dhall helper per kind,
`packs/kikan-shikigami-binding/dhall/Outputs.dhall`. They load only in an executable composed
with the binding (the `kikan-shikigami-*` distribution); a stock executable refuses them at
load and names the kinds it does register (plan 135, M3).

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

| Output kind | Produces | Status in this runtime |
| --- | --- | --- |
| **KawaDigest** (`kawa.digest`) | a digest activity written back into the stream | fully implemented (against the kawa stub) |
| **KizashiSignal** (`kizashi.signal`) | an awareness signal | fully implemented (against the kizashi client/stub) |
| **ReiAction** (`rei.action`) | an action recorded against a `rei` intention | implemented when a Rei endpoint is configured; otherwise fails visibly |
| **DanwaConversation** (`danwa.conversation`) | an opened/attached conversation | fully implemented through the Danwa client |
| **ChannelEgress** (`channel.egress`) | a reply or other approved action on an external conversation | fully implemented through Kanmon |

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
journal or outbox. Exact target identifiers reject reserved tuple separators such as `:` and `#`.
An authorization-service outage or rejected proof is reported as `AuthorizationFailed`, creates
no enqueue row, and performs no delivery IO. See
[Per-action authorization operations](../operations/action-authorization.md).

This means you can **declare** sinks freely and control which ones an agent is actually
permitted to fire through the grant layer — declaration and authorization are separate
concerns.

Flow-owned emissions are permission-gated even when the declaration's `sinks` list is empty. The
OpenTelemetry practice reviewer deliberately uses this form so Kawa history and coalesced Kizashi
attention occur at explicit lifecycle points rather than generic post-behavior dispatch.

## A sink-free agent

`sinks` defaults to `[]`, so an agent can run its behavior and record a session while
producing nothing outward — useful for an agent whose only job is to **learn** (record memory)
for its future runs. See **[Memory & Sessions](./memory.md)**.
