let A = ../../../schema/Agent.dhall

let K = ../../../packs/kikan-shikigami-binding/dhall/Outputs.dhall
in  A.Agent::{
    , name = "triage-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger =
        A.Trigger.Stream
          { match =
              { verb = Some "ticket.received"
              , source = None Text
              , subjectType = Some "ticket"
              , verbs = [] : List Text
              }
          }
    , outputs =
        [ K.kizashiSignal K.KizashiSignal::
            { source = "shinzui/shikigami"
            , signalType = K.SignalType.TaskCandidate
            , priority = K.Priority.Normal
            , importance = 45
            , recipientFrom = K.RecipientFrom.SubjectOwner
            , defaultRecipient = Some "person:nadeem"
            , intentTemplate = "triage this ticket"
            , extraContextTags = [ "verb:ticket.received", "subject:ticket" ]
            }
        ]
    }
