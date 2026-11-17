let A = ../schema/Agent.dhall

let K = ../packs/kikan-shikigami-binding/dhall/Outputs.dhall
in  A.Agent::{
    , name = "danwa-heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          }
    , trigger = A.Trigger.Event { eventType = "danwa.message-addressed-to-agent" }
    , outputs = [ K.danwaConversation { topic = "support" } ]
    }
