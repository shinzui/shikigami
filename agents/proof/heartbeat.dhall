let A = ../../schema/Agent.dhall

let K = ../../packs/kikan-shikigami-binding/dhall/Outputs.dhall
in  A.Agent::{
    , name = "heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , outputs = [ K.kawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
