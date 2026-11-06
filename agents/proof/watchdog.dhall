let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "watchdog"
    , description = "Reports stuck and drifting active work through advisory findings"
    , trigger = A.Trigger.Schedule { cron = "*/5 * * * *" }
    , behavior = A.Behavior.Flow { name = "watchdog-sweep" }
    , identity = Some { principal = "agent_watchdog" }
    , decisionModels = [ "drift" ]
    }
