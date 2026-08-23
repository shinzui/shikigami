-- schema/Agent.dhall — the canonical C5 agent-definition schema (EP-1, IP-2).
-- This is the SUPERSET reconciling the spec's illustrative schema (docs/initial-spec.md)
-- and the seed detector schema (agents/detectors/schema.dhall). EP-6 re-points the seeds
-- at this file as a mechanical rename (singular `sink` -> `sinks = [ ... ]`; Observe ->
-- Stream; Deterministic kept; RaiseSignal -> KizashiSignal).

let SignalType =
      < Notification | Alert | Reminder | TaskCandidate | DigestItem | AgentRequest >

let Priority = < Low | Normal | High | Urgent >

let RecipientFrom = < SubjectOwner | AreaOwner | Actor >

-- C3's three trigger classes, named to match the spec's C5 vocabulary.
let StreamMatch =
      { verb : Optional Text
      , source : Optional Text
      , subjectType : Optional Text
      , verbs : List Text          -- the seeds' multi-verb match (empty = any verb)
      }

let Trigger =
      < Schedule : { cron : Text }
      | Stream : { match : StreamMatch }
      | Event : { eventType : Text }
      >

-- The behavior union covers all three arms the seeds and the spec need.
let Behavior =
      < Deterministic :
          { rule : Text, params : List { mapKey : Text, mapValue : Text } }
      | ShikumiProgram :
          { task : Text
          , preferEnrichment : Bool
          , grounding : Optional Text
          , enabledBy : Optional Text
          }
      | Skill : { path : Text }
      | Flow : { name : Text }
      >

-- The producer sink set. KizashiSignal carries the seeds' rich RaiseSignal fields.
let Sink =
      < KawaDigest : { subjectType : Text, verb : Text }
      | KizashiSignal :
          { source : Text
          , signalType : SignalType
          , priority : Priority
          , importance : Natural
          , recipientFrom : RecipientFrom
          , defaultRecipient : Optional Text
          , intentTemplate : Text
          , extraContextTags : List Text
          }
      | ReiAction : { intentionId : Text, note : Text }
      | DanwaConversation : { topic : Text }
      | ChannelEgress :
          { channel : Text
          , action : Text
          , conversationKey : Optional Text
          }
      >

let ProfileRequirement =
      { Type = { profileId : Text, version : Optional Text }
      , default = { version = None Text }
      }

let Identity = { principal : Text }

let MemoryScope = < AgentScope | Shared >

let RecordPolicy = < Always | OnSuccess | Never >

let MemoryPolicy =
      { scope : MemoryScope
      , recallLimit : Natural
      , recordPolicy : RecordPolicy
      }

let defaultMemoryPolicy =
      { scope = MemoryScope.AgentScope
      , recallLimit = 10
      , recordPolicy = RecordPolicy.OnSuccess
      }

let Expertise =
      { key : Text
      , description : Text
      , aliases : List Text
      , evidenceHints : List Text
      }

let RouterConfidence = < RoutingLow | RoutingMedium | RoutingHigh >

let NoMatchPolicy = < ReturnNoMatch | ReturnUnresolved >

let AmbiguousPolicy = < ReturnAmbiguous | SelectAllWithinBound >

let RouterPolicy =
      { maxSelections : Natural
      , minimumConfidence : RouterConfidence
      , onNoMatch : NoMatchPolicy
      , onAmbiguous : AmbiguousPolicy
      }

let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , sinks : List Sink
          , delegates : List Text
          , delegationBudget : Optional Natural
          , sanctionedProfile : Optional ProfileRequirement.Type
          , capabilityOverlays : List Text
          , identity : Optional Identity
          , memory : MemoryPolicy
          , enabled : Bool
          , expertise : List Expertise
          , routing : Optional RouterPolicy
          }
      , default =
          { description = ""
          , sinks = [] : List Sink
          , delegates = [] : List Text
          , delegationBudget = None Natural
          , sanctionedProfile = None ProfileRequirement.Type
          , capabilityOverlays = [] : List Text
          , identity = None Identity
          , memory = defaultMemoryPolicy
          , enabled = True
          , expertise = [] : List Expertise
          , routing = None RouterPolicy
          }
      }

in  { SignalType
    , Priority
    , RecipientFrom
    , StreamMatch
    , Trigger
    , Behavior
    , Sink
    , ProfileRequirement
    , Identity
    , MemoryScope
    , RecordPolicy
    , MemoryPolicy
    , Expertise
    , RouterConfidence
    , NoMatchPolicy
    , AmbiguousPolicy
    , RouterPolicy
    , Agent
    }
