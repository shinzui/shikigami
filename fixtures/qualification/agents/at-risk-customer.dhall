let A = ../../../schema/Agent.dhall
in  A.Agent::{
    , name = "qualification-at-risk-customer"
    , description = "Qualification of the existing durable customer approval Flow."
    , identity = Some { principal = "agent_qualification_at_risk" }
    , trigger = A.Trigger.Event { eventType = "qualification.customer-risk" }
    , behavior = A.Behavior.Flow { name = "at-risk-customer" }
    , sinks = [ A.Sink.KizashiSignal
        { source = "shinzui/shikigami"
        , signalType = A.SignalType.Alert
        , priority = A.Priority.High
        , importance = 80
        , recipientFrom = A.RecipientFrom.AreaOwner
        , defaultRecipient = None Text
        , intentTemplate = "Qualification customer risk"
        , extraContextTags = [] : List Text
        }
      ]
    }
