--| at-risk-customer — a schema-valid seed for a future Shikumi classifier.
--
-- The task is not registered. Shikigami owns the local Shikumi execution adapter;
-- this declaration does not enable a model-backed detector. The proposed
-- classifier prefers enrichment sentiment/risks before classifying payload.text.
-- Its signature, enrichment precedence and optional grounding remain design in
-- docs/initial-spec.md. See ./README.md and docs/user/detectors.md for support.
-- enabledBy and preferEnrichment are declaration metadata, not runtime gates.
--
-- Origin: docs/plans/12-the-intelligence-layer-continuous-observation-to-signals.md

let Schema = ../../schema/Agent.dhall

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
          Trigger.Stream
            { match =
                { verb = None Text
                , source = None Text
                , subjectType = Some "ticket"
                , verbs = [ "ticket.received" ]
                }
            }
      , -- BEHAVIOR (C5): a Shikumi Program run by the local adapter. The program FIRST reads
        -- `payload.enrichment.sentiment` / `payload.enrichment.risks` (C7): if
        -- present, derive the verdict from them (sentiment = negative AND a
        -- non-empty `risks` containing "churn risk" -> high) with no model call.
        -- If absent, run the `at-risk-customer` shikumi program over
        -- `payload.text`. `task` names the proposed Shikumi program (signature
        -- `Signature TicketInput RiskVerdict`);
        -- `grounding` optionally loads an OKF "churn risk" concept (C10) when EP-9
        -- is available; `enabledBy` records a proposed config flag.
        behavior =
          Behavior.ShikumiProgram
            { task = "at-risk-customer"
            , preferEnrichment = True
            , grounding = None Text
            , enabledBy = Some "TOMOSHIBI_ENABLE_LLM_DETECTORS"
            }
      , -- SINK (C4): on a `high` verdict raise a kizashi Alert. awareness.md
        -- Source-3 (model judgments): high-risk verdict -> Alert, Shared inbox,
        -- escalate after timeout. priority High (Urgent when the payload marks the
        -- ticket critical), importance 70-89. `intent` carries the verdict
        -- rationale; contextTags ALWAYS include `activity://<activity_id>` (C4).
        sinks =
          [ Sink.KizashiSignal
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
          ]
      }
