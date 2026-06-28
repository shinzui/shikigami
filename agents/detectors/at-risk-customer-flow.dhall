--| at-risk-customer-flow — durable-flow version of the at-risk customer detector.
--
-- This declaration keeps trigger/identity in Dhall and names the compiled Haskell
-- flow that classifies, raises an alert, waits for acknowledgement, and escalates
-- on timeout. Sinks are empty because the flow emits its alert/escalation through
-- the transactional outbox at the exact mid-run lifecycle points.

let Schema = ../../schema/Agent.dhall

let Agent = Schema.Agent

let Trigger = Schema.Trigger

let Behavior = Schema.Behavior

in    Agent::{
      , name = "at-risk-customer"
      , description =
          "Raise an Alert for at-risk customer tickets, wait for acknowledgement, and escalate on timeout."
      , trigger =
          Trigger.Stream
            { match =
                { verb = None Text
                , source = None Text
                , subjectType = Some "ticket"
                , verbs = [ "ticket.received" ]
                }
            }
      , behavior = Behavior.Flow { name = "at-risk-customer" }
      , sinks = [] : List Schema.Sink
      }
