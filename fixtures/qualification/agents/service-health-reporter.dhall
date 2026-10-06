let A = ../../../schema/Agent.dhall
in  A.Agent::{
    , name = "service-health-reporter"
    , description = "Report supplied service health snapshots and recall earlier service health reports."
    , identity = Some { principal = "agent_qualification_reporter" }
    , trigger = A.Trigger.Event { eventType = "qualification.service-health" }
    , behavior = A.Behavior.Skill { path = "fixtures/qualification/skills/service-health" }
    , sinks = [ A.Sink.KawaDigest { subjectType = "service-health", verb = "qualification.health.report" } ]
    , memory = { scope = A.MemoryScope.AgentScope, recallLimit = 3, recordPolicy = A.RecordPolicy.OnSuccess }
    }
