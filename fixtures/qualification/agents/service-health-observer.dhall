let A = ../../../schema/Agent.dhall

-- The qualification closure is the stock composition (ADR-39), which registers
-- no Kikan output, so these agents keep their results in the journal.
in  A.Agent::{
    , name = "service-health-observer"
    , description = "Report supplied service health snapshots and recall earlier service health reports."
    , identity = Some { principal = "agent_qualification_observer" }
    , trigger = A.Trigger.Event { eventType = "qualification.service-health" }
    , behavior = A.Behavior.Skill { path = "fixtures/qualification/skills/service-health" }
    , outputs = [] : List A.Output
    , memory = { scope = A.MemoryScope.AgentScope, recallLimit = 3, recordPolicy = A.RecordPolicy.OnSuccess }
    }
