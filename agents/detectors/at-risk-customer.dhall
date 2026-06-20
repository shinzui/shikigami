--| at-risk-customer — an LLM-backed declared detector agent on the shikigami runtime.
--
-- A judgment over unstructured text: it reads a support-ticket activity and
-- decides whether the customer relationship is at risk. It PREFERS EP-4's
-- enrichment facts (`payload.enrichment.sentiment` and `payload.enrichment.risks`,
-- contract C7) and only classifies the raw `payload.text` via a
-- `shinzui/shikumi`/`shinzui/handan` program when those facts are absent — so it
-- is demonstrable before EP-4 lands. On a high-risk verdict it raises a
-- `shinzui/kizashi` Alert ("a customer relationship needs attention").
--
-- This is the LLM half of the catalog: most patterns are deterministic and must
-- not pay LLM latency/cost (see stalled-intention.dhall), but "this ticket's
-- sentiment indicates an at-risk relationship" justifies a model call.
--
-- Schema: contract C5 — `{ name, behavior, trigger, sink }`. `behavior` is a
-- union; this detector uses the `Program` arm — a `shikumi` Program run via
-- `shinzui/handan`. The shikumi signature (`Signature TicketInput RiskVerdict`),
-- the handan decision-task wrapping, the enrichment-facts-first / text-fallback
-- precedence, and optional OKF "churn risk" grounding (C10) are preserved as
-- DESIGN in the shikigami initial-spec "Worked agents" section and summarized in
-- ./README.md. The input/output records follow handan's worked example
-- `SmokeInput`/`SmokeOutput` in handan-core/src/Handan/Task.hs.
--
-- LLM detectors are OPT-IN behind `TOMOSHIBI_ENABLE_LLM_DETECTORS` (default off)
-- so the deterministic path needs no credentials and CI stays hermetic.
--
-- Origin: docs/plans/12-the-intelligence-layer-continuous-observation-to-signals.md
-- (EP-5), Milestone 2. Conforms to awareness.md Source-3.

let Schema = ./schema.dhall

let Agent = Schema.Agent

let Trigger = Schema.Trigger

let Behavior = Schema.Behavior

let Sink = Schema.Sink

let SignalType = Schema.SignalType

let Priority = Schema.Priority

in    Agent::{
      , name = "at-risk-customer"
      , description =
          "Raise an Alert when a support ticket signals a customer relationship at risk (LLM-backed)."
      , -- TRIGGER (C3, observe class): an `activity.v1` stream pattern on support
        -- tickets. External sources use `source = external/<system>` (C1); a
        -- synthetic source + verb `ticket.received` suffices for a demo without EP-4.
        trigger =
          Trigger.Observe
            { topic = "activity.v1"
            , subjectType = Some "ticket"
            , verbs = [ "ticket.received" ]
            }
      , -- BEHAVIOR (C5): a shikumi Program run via handan. The program FIRST reads
        -- `payload.enrichment.sentiment` / `payload.enrichment.risks` (C7): if
        -- present, derive the verdict from them (sentiment = negative AND a
        -- non-empty `risks` containing "churn risk" -> high) with no model call.
        -- If absent, run the `at-risk-customer` shikumi program over
        -- `payload.text`. `program` names the handan/shikumi program (signature
        -- `Signature TicketInput RiskVerdict`, wrapped as a `Handan.Task.decisionTask`);
        -- `grounding` optionally loads an OKF "churn risk" concept (C10) when EP-9
        -- is available; `enabledBy` gates the LLM path behind a config flag.
        behavior =
          Behavior.Program
            { program = "at-risk-customer"
            , preferEnrichment = True
            , grounding = None Text
            , enabledBy = Some "TOMOSHIBI_ENABLE_LLM_DETECTORS"
            }
      , -- SINK (C4): on a `high` verdict raise a kizashi Alert. awareness.md
        -- Source-3 (handan judgments): high-risk verdict -> Alert, Shared inbox,
        -- escalate after timeout. priority High (Urgent when the payload marks the
        -- ticket critical), importance 70-89. `intent` carries the verdict
        -- rationale; contextTags ALWAYS include `activity://<activity_id>` (C4).
        sink =
          Sink.RaiseSignal
            { source = "shinzui/shikigami"
            , signalType = SignalType.Alert
            , priority = Priority.High
            , importance = 80
            , recipientFrom = Schema.RecipientFrom.AreaOwner
            , defaultRecipient = Some "role_relationship_owner"
            , intentTemplate = "{verdict.rationale}"
            , extraContextTags =
                [ "verb:relationship.at_risk", "subject:ticket" ]
            }
      }
