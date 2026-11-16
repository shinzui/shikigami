--| objective-example: create an objective, plan one assignment, record
-- progress and read it back, through the kernel's Objectives capability.
--
-- The flow lives in this pack. Run it from a worker composed with the pack
-- (kikan-shikigami-worker); the stock worker refuses the manifest. The
-- principal must be active in the directory and listed in
-- objectives.agentCreation.

let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "objective-example"
    , description = "Create and progress one objective from a flow."
    , identity = Some { principal = "agent_objective_example" }
    , behavior = A.Behavior.Flow { name = "objective-example" }
    , sinks = [] : List A.Sink
    , memory =
      { scope = A.MemoryScope.AgentScope
      , recallLimit = 1
      , recordPolicy = A.RecordPolicy.Never
      }
    }
