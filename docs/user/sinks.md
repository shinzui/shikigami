# Sinks — *what* an agent produces

Agents are **producers, not just reactors**. A sink is an outward action the agent takes with
its behavior's output. An agent declares zero or more sinks; each is dispatched after the
behavior runs and is **gated by a permission check**.

```dhall
let Sink =
      < KawaDigest        : { subjectType : Text, verb : Text }
      | KizashiSignal     : { source : Text, signalType : SignalType, priority : Priority
                            , importance : Natural, recipientFrom : RecipientFrom
                            , defaultRecipient : Optional Text, intentTemplate : Text
                            , extraContextTags : List Text }
      | ReiAction         : { intentionId : Text, note : Text }
      | DanwaConversation : { topic : Text }
      >
```

| Sink | Produces | Status in this runtime |
| --- | --- | --- |
| **KawaDigest** | a digest activity written back into the stream | fully implemented (against the kawa stub) |
| **KizashiSignal** | an awareness signal | fully implemented (against the kizashi client/stub) |
| **ReiAction** | an action recorded against a `rei` intention | schema + stub handler (completed by `rei`'s plan) |
| **DanwaConversation** | an opened/attached conversation | schema + stub handler (completed by EP-7) |

## KawaDigest — write back to the stream

```dhall
A.Sink.KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" }
```

Builds a nine-field **Activity Envelope** from the behavior's output and POSTs it to kawa's
ingest doorway. The runtime fills the envelope: `source = "shinzui/shikigami"`,
`actor.kind = "agent"` (so the rest of the system can tell agent-produced memory from human
memory), `subject.type` and `verb` from this config, and `payload` from the behavior's
output. It mints the envelope's UUIDv7 `activity_id` itself and derives an idempotency key so
re-delivery is a no-op.

This is the sink that **closes the living loop**: a digest written here reappears on
`activity.v1` and can trigger a second agent. See **[The Living Loop](./living-loop.md)**.

## KizashiSignal — raise awareness

```dhall
A.Sink.KizashiSignal
  { source = "shinzui/shikigami"
  , signalType = A.SignalType.TaskCandidate
  , priority = A.Priority.Normal
  , importance = 45
  , recipientFrom = A.RecipientFrom.SubjectOwner
  , defaultRecipient = Some "person:nadeem"
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
A.Sink.ReiAction { intentionId = "intention_01k…", note = "delegation overdue" }
```

The explicit, designed bridge from a **shikigami** (system) agent into **rei**'s
(intention-bound) context. When a finding concerns a *specific intention*, this sink records
an action **against that target intention** through `rei`'s **command API** under the agent's
`shomei` identity — **never** by touching `rei`'s store directly. `intentionId` names the
target intention; `note` is the action's content.

This runtime *defines* the variant and stubs the handler; the real `rei` command-API call is
completed by `rei`'s own plan. The contract is fixed: command API + shomei `act` claim, never
the store.

## DanwaConversation — open/attach a conversation

```dhall
A.Sink.DanwaConversation { topic = "incident-42" }
```

Opens or attaches a `shinzui/danwa` conversation on the given topic. Schema variant with a
stub handler in this runtime; completed by its owning plan (EP-7).

## The permission gate

**Every sink dispatch is gated by a permission check** tied to the agent's identity. If a
sink is **denied**, it is **logged and skipped** — the run still completes, and the session
records the denial. A denied sink never crashes the agent.

In this runtime the check consults a stub allow-list keyed by agent name; the seam is shaped
so it can be swapped for a real `shomei` grant lookup with no schema change. Coarse scopes
(`kawa:ingest`, `signal:raise`, …) live in `shomei`; fine-grained per-agent-per-sink grants
live in a local grant table keyed by the verified subject.

This means you can **declare** sinks freely and control which ones an agent is actually
permitted to fire through the grant layer — declaration and authorization are separate
concerns.

## A sink-free agent

`sinks` defaults to `[]`, so an agent can run its behavior and record a session while
producing nothing outward — useful for an agent whose only job is to **learn** (record memory)
for its future runs. See **[Memory & Sessions](./memory.md)**.
