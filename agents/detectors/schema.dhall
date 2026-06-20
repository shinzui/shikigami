--| schema.dhall — the local C5 agent-definition schema the detector declarations
-- in this directory annotate against.
--
-- IMPORTANT: this is a SEED / placeholder schema authored alongside the first
-- detectors (EP-5). The CANONICAL agent-definition schema is owned by the
-- shikigami runtime (EP-6, contract C5) and is specified in the shikigami
-- initial-spec. When the runtime publishes its concrete `Agent` Dhall type, this
-- file should be replaced by an import of the runtime's schema (e.g.
-- `let Schema = ../../dhall/agent.dhall`), and the detector declarations re-run
-- unchanged. This seed exists so the `.dhall` files in this directory are
-- self-contained and the design (trigger pattern, behavior union, sink config) is
-- fully expressed and reviewable before the runtime lands.
--
-- Schema shape (C5): `{ name, behavior, trigger, sink }`. Per C5 the `behavior` is
-- a UNION — not everything needs a typed program: a `shikumi` Program (run via
-- handan) OR a Skill (Agent Skills spec). The detectors here use the `Program`
-- arm (LLM) and a `Deterministic` arm (a cheap rule); the `Skill` arm is declared
-- for completeness so the recipe in README.md can describe all behavior kinds.

let SignalType =
      < Notification
      | Alert
      | Reminder
      | TaskCandidate
      | DigestItem
      | AgentRequest
      >

let Priority = < Low | Normal | High | Urgent >

let RecipientFrom =
      < -- the intention/subject owner (the declaration's `actor.id`)
        SubjectOwner
      | -- a configured area/relationship owner
        AreaOwner
      | -- always the declaration's actor
        Actor
      >

let -- C3 trigger classes (C5 `trigger`). Detectors use the Observe class (an
    -- `activity.v1` stream pattern); Schedule and Addressed are declared so the
    -- README recipe can describe the full surface.
    Trigger =
      < Observe :
          { topic : Text
          , subjectType : Optional Text
          , verbs : List Text
          }
      | Schedule : { cron : Text }
      | Addressed : { inbox : Text }
      >

let -- C5 `behavior` union.
    Behavior =
      < -- a cheap deterministic rule named by the runtime's rule library
        Deterministic :
          { rule : Text, params : List { mapKey : Text, mapValue : Text } }
      | -- a typed shikumi Program run via handan (LLM-backed)
        Program :
          { program : Text
          , preferEnrichment : Bool
          , grounding : Optional Text
          , enabledBy : Optional Text
          }
      | -- an Agent Skills directory run directly through baikai
        Skill : { dir : Text }
      >

let -- C5 `sink` (one or more output actions). The detectors here use only the
    -- kizashi RaiseSignal sink (C4); RecordReiAction is declared for future
    -- intention-driving detectors (the rei bridge, C5).
    Sink =
      < RaiseSignal :
          { source : Text
          , signalType : SignalType
          , priority : Priority
          , importance : Natural
          , recipientFrom : RecipientFrom
          , defaultRecipient : Optional Text
          , intentTemplate : Text
          , extraContextTags : List Text
          }
      | RecordReiAction : { command : Text }
      >

let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , sink : Sink
          }
      , default = {=}
      }

in  { SignalType
    , Priority
    , RecipientFrom
    , Trigger
    , Behavior
    , Sink
    , Agent
    }
