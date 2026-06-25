let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "broken"
    , behaviour = A.Behavior.Skill { path = "agents/skills/triage-note" }   -- typo: behaviour vs behavior
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    }
