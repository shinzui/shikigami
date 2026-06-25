let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "digest-watcher"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger =
        A.Trigger.Stream
          { match =
              { verb = Some "heartbeat.tick"
              , source = None Text
              , subjectType = Some "heartbeat"
              , verbs = [] : List Text
              }
          }
    , sinks = [] : List A.Sink
    }
