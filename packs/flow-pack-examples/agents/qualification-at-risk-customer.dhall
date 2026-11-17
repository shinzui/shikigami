let A = ../../../schema/Agent.dhall

let K = ../../../schema/outputs/Kikan.dhall
in  A.Agent::{
    , name = "qualification-at-risk-customer"
    , description = "Qualification of the existing durable customer approval Flow."
    , identity = Some { principal = "agent_qualification_at_risk" }
    , trigger = A.Trigger.Event { eventType = "qualification.customer-risk" }
    , behavior = A.Behavior.Flow { name = "at-risk-customer" }
    , outputs = [ K.kizashiSignal K.KizashiSignal::
        { source = "shinzui/shikigami"
        , signalType = K.SignalType.Alert
        , priority = K.Priority.High
        , importance = 80
        , recipientFrom = K.RecipientFrom.AreaOwner
        , defaultRecipient = Some "role_relationship_owner"
        , intentTemplate = "Qualification customer risk"
        , extraContextTags = [] : List Text
        }
      ]
    }
