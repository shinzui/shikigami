--| stalled-intention — the first declared detector agent on the shikigami runtime.
--
-- A *detector* is an agent whose whole job is to watch the unified activity
-- stream and raise a `shinzui/kizashi` signal when a pattern matters. This one is
-- the cheap, deterministic case: "an `intention` subject was declared but has had
-- no `action.recorded` for N days (default 7)". It is `shinzui/rei`'s
-- `OnIntentionStalled` reactor pattern lifted out of rei's single bounded context
-- and run portfolio-wide over the whole river, expressed as a *declared agent*
-- rather than rei-internal code.
--
-- Schema: contract C5 — `{ name, behavior, trigger, sink }`. `behavior` is a
-- union; this detector uses the `Deterministic` arm (no LLM, no credentials). See
-- ./README.md for the schema definition, the per-subject window, and the
-- suppression-table design; see the shikigami initial-spec "Worked agents"
-- section for the rule's evaluation semantics. The runtime (EP-6) owns the
-- concrete Dhall type and import path; until it publishes `./schema.dhall`, this
-- file is annotated against the local schema documented in README.md.
--
-- Origin: docs/plans/12-the-intelligence-layer-continuous-observation-to-signals.md
-- (EP-5), Milestone 1. Conforms to awareness.md Source-1.

let Schema = ./schema.dhall

let Agent = Schema.Agent

let Trigger = Schema.Trigger

let Behavior = Schema.Behavior

let Sink = Schema.Sink

let SignalType = Schema.SignalType

let Priority = Schema.Priority

in    Agent::{
      , name = "stalled-intention"
      , description =
          "Raise a Reminder when a declared intention has had no recorded action for N days."
      , -- TRIGGER (C3, observe class): an `activity.v1` stream pattern. Match
        -- activities about an intention: the declaration enters the per-subject
        -- window; a later `action.recorded` clears the stalled condition.
        trigger =
          Trigger.Observe
            { topic = "activity.v1"
            , subjectType = Some "intention"
            , verbs = [ "intention.declared", "action.recorded" ]
            }
      , -- BEHAVIOR (C5): a deterministic rule, parameterized by N days. Over the
        -- subject's window, if there is an `intention.declared` with no later
        -- `action.recorded` and `now - lastDeclared >= N days`, produce one
        -- finding; otherwise none. The window key is the declaration's
        -- `occurred_at` truncated to the day, so re-evaluating within the same
        -- staleness episode dedups (suppression, Milestone 3) but a fresh
        -- declaration gets a new key and may legitimately re-fire.
        behavior =
          Behavior.Deterministic
            { rule = "stalled-intention"
            , params = toMap { staleAfterDays = "7" }
            }
      , -- SINK (C4): raise a kizashi Reminder. awareness.md Source-1:
        -- `intention.at_risk` (subject `intention`) -> Reminder / TaskCandidate,
        -- owning human's Personal inbox, priority Normal, importance 40-69.
        -- `source` is this runtime's mori identity; `actor` (audit) is filled by
        -- the runtime from the triggering activity's `<source>:<actor.id>`;
        -- `recipient` is the intention owner (the declaration's `actor.id`,
        -- falling back to the configured default); contextTags ALWAYS include
        -- `activity://<activity_id>` (C4 back-reference).
        sink =
          Sink.RaiseSignal
            { source = "shinzui/shikigami"
            , signalType = SignalType.Reminder
            , priority = Priority.Normal
            , importance = 45
            , recipientFrom = Schema.RecipientFrom.SubjectOwner
            , defaultRecipient = Some "person:nadeem"
            , intentTemplate =
                "intention '{subject.title}' has had no action for {params.staleAfterDays} days"
            , extraContextTags = [ "verb:intention.at_risk", "subject:intention" ]
            }
      }
