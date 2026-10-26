let A = ../../../schema/Agent.dhall
in  A.Agent::{
    , name = "heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , sinks = [] : List A.Sink
    }
