-- The Kikan outputs (plan 135, M3 of MasterPlan 22): one typed helper per
-- output kind, each rendering the kind's JSON configuration. A declaration
-- that uses one loads only where a composition registers that kind, which is
-- the Kikan distribution; the stock composition refuses it at load and lists
-- the kinds it does register.
--
--   let K = ../schema/outputs/Kikan.dhall
--   in  A.Agent::{ ..., outputs = [ K.kawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ] }
let A = ../Agent.dhall

let SignalType =
      < Notification | Alert | Reminder | TaskCandidate | DigestItem | AgentRequest >

let Priority = < Low | Normal | High | Urgent >

let RecipientFrom = < SubjectOwner | AreaOwner | Actor >

-- JSON text for a Dhall Text: Text/show escapes exactly what JSON needs.
let string = \(t : Text) -> Text/show t

let optional =
      \(o : Optional Text) -> merge { None = "null", Some = string } o

let strings =
      \(xs : List Text) ->
            "["
        ++  merge
              { None = "", Some = \(joined : Text) -> joined }
              ( List/fold
                  Text
                  xs
                  (Optional Text)
                  ( \(x : Text) ->
                    \(rest : Optional Text) ->
                      Some
                        ( merge
                            { None = string x
                            , Some = \(r : Text) -> string x ++ "," ++ r
                            }
                            rest
                        )
                  )
                  (None Text)
              )
        ++  "]"

let signalTypeText =
      \(t : SignalType) ->
        merge
          { Notification = "Notification"
          , Alert = "Alert"
          , Reminder = "Reminder"
          , TaskCandidate = "TaskCandidate"
          , DigestItem = "DigestItem"
          , AgentRequest = "AgentRequest"
          }
          t

let priorityText =
      \(p : Priority) ->
        merge { Low = "Low", Normal = "Normal", High = "High", Urgent = "Urgent" } p

let recipientFromText =
      \(r : RecipientFrom) ->
        merge
          { SubjectOwner = "SubjectOwner", AreaOwner = "AreaOwner", Actor = "Actor" }
          r

-- One C1 activity envelope in Kawa.
let kawaDigest =
      \(o : { subjectType : Text, verb : Text }) ->
          { kind = "kawa.digest"
          , config =
                  "{\"subjectType\":"
              ++  string o.subjectType
              ++  ",\"verb\":"
              ++  string o.verb
              ++  "}"
          }
        : A.Output

-- One C4 signal in Kizashi. recipientFrom says how to find the recipient from
-- the trigger activity; defaultRecipient is the fallback.
let KizashiSignal =
      { Type =
          { source : Text
          , signalType : SignalType
          , priority : Priority
          , importance : Natural
          , recipientFrom : RecipientFrom
          , defaultRecipient : Optional Text
          , intentTemplate : Text
          , extraContextTags : List Text
          }
      , default =
        { recipientFrom = RecipientFrom.Actor
        , defaultRecipient = None Text
        , extraContextTags = [] : List Text
        }
      }

let kizashiSignal =
      \(o : KizashiSignal.Type) ->
          { kind = "kizashi.signal"
          , config =
                  "{\"source\":"
              ++  string o.source
              ++  ",\"signalType\":"
              ++  string (signalTypeText o.signalType)
              ++  ",\"priority\":"
              ++  string (priorityText o.priority)
              ++  ",\"importance\":"
              ++  Natural/show o.importance
              ++  ",\"recipientFrom\":"
              ++  string (recipientFromText o.recipientFrom)
              ++  ",\"defaultRecipient\":"
              ++  optional o.defaultRecipient
              ++  ",\"intentTemplate\":"
              ++  string o.intentTemplate
              ++  ",\"extraContextTags\":"
              ++  strings o.extraContextTags
              ++  "}"
          }
        : A.Output

-- One action against a Rei intention.
let reiAction =
      \(o : { intentionId : Text, note : Text }) ->
          { kind = "rei.action"
          , config =
                  "{\"intentionId\":"
              ++  string o.intentionId
              ++  ",\"note\":"
              ++  string o.note
              ++  "}"
          }
        : A.Output

-- A post into a fresh Danwa thread whose opening line is the topic.
let danwaConversation =
      \(o : { topic : Text }) ->
        { kind = "danwa.conversation"
        , config = "{\"topic\":" ++ string o.topic ++ "}"
        }
        : A.Output

-- One guarded channel action through Kanmon.
let ChannelEgress =
      { Type =
          { channel : Text, action : Text, conversationKey : Optional Text }
      , default.conversationKey = None Text
      }

let channelEgress =
      \(o : ChannelEgress.Type) ->
          { kind = "channel.egress"
          , config =
                  "{\"channel\":"
              ++  string o.channel
              ++  ",\"action\":"
              ++  string o.action
              ++  ",\"conversationKey\":"
              ++  optional o.conversationKey
              ++  "}"
          }
        : A.Output

in  { SignalType
    , Priority
    , RecipientFrom
    , kawaDigest
    , KizashiSignal
    , kizashiSignal
    , reiAction
    , danwaConversation
    , ChannelEgress
    , channelEgress
    }
