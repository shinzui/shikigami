let A = ../../../schema/Agent.dhall
in  A.Agent::{
    , name = "disabled-heartbeat"
    , enabled = False
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , sinks = [ A.Sink.KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
