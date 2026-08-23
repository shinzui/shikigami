let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "channel-reply"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "channel.message_received" }
    , sinks =
        [ A.Sink.ChannelEgress
            { channel = "intercom"
            , action = "reply_to_conversation"
            , conversationKey = None Text
            }
        ]
    }
