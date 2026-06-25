let A = ../schema/Agent.dhall
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
    , sinks =
        [ A.Sink.KizashiSignal
            { source = "shinzui/shikigami"
            , signalType = A.SignalType.TaskCandidate
            , priority = A.Priority.Normal
            , importance = 45
            , recipientFrom = A.RecipientFrom.SubjectOwner
            , defaultRecipient = Some "person:nadeem"
            , intentTemplate = "triage this ticket"
            , extraContextTags = [ "verb:ticket.received", "subject:ticket" ]
            }
        ]
    }
