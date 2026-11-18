-- A Skill agent that names its local output explicitly (docs/user/outputs.md).
let A = ../../../schema/Agent.dhall

let Local = ../../../schema/outputs/Local.dhall

in  A.Agent::{
    , name = "plain-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/plain-note" }
    , outputs = [ Local.report Local.Format.Json ]
    }
