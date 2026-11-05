let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "proposer"
    , description =
        "Notices actionable work in observed chat and transcripts and proposes it; starts nothing without a person or a standing policy."
    , trigger =
        A.Trigger.Stream
          { match =
            { verb = None Text
            , source = Some "fixture/chat"
            , subjectType = None Text
            , verbs = [] : List Text
            }
          }
    , behavior = A.Behavior.Flow { name = "propose-work" }
    , identity = Some { principal = "agent_shikigami_proposer" }
    , decisionModels = [ "propose" ]
    }
