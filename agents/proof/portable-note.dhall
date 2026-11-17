-- The portability proof (EP-8 M3 of MasterPlan 22): one declaration in
-- kernel vocabulary only. It names no trigger (so it is Trigger.Manual), no
-- outputs (so the composition's default output receives its summary) and no
-- capability overlay, because each overlay is registered by only some
-- compositions (workspace.read only by the light commands). The README to
-- summarize arrives as the trigger payload. The same file runs under the stock
-- local-operator composition and under a Kikan composition;
-- `shikigami record check --run <id>` checks each run's action record.
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "portable-note"
    , description = "Proof agent: summarizes a README in kernel vocabulary only"
    , behavior = A.Behavior.Skill { path = "agents/skills/portable-note" }
    , identity = Some { principal = "agent_01h000000000000000portable" }
    }
