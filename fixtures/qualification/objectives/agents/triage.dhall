let A = ../../../../schema/Agent.dhall
in A.Agent::{
  , name = "triage"
  , identity = Some { principal = "agent_01h000000000000000triage" }
  , description = "Disposable objective qualification participant"
  , trigger = A.Trigger.Event { eventType = "qualification.objectives" }
  , behavior = A.Behavior.Skill { path = "fixtures/qualification/objectives/skills/objectives" }
  , sinks = [] : List A.Sink
  , memory = { scope = A.MemoryScope.AgentScope, recallLimit = 1, recordPolicy = A.RecordPolicy.Never }
  }
