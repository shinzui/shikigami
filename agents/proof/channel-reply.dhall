let A = ../../schema/Agent.dhall

let K = ../../packs/kikan-shikigami-binding/dhall/Outputs.dhall

in  A.Agent::{
    , name = "channel-reply"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          }
    , trigger = A.Trigger.Event { eventType = "channel.message_received" }
    , outputs =
        [ K.channelEgress K.ChannelEgress::
            { channel = "intercom"
            , action = "reply_to_conversation"
            , conversationKey = None Text
            }
        ]
    }
