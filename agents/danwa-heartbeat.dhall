let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "danwa-heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "danwa.message-addressed" }
    , sinks = [ A.Sink.DanwaConversation { topic = "support" } ]
    }
