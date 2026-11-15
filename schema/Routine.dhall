-- The routine-agent prelude (EP-9 of MasterPlan 22): short forms that return
-- ordinary declarations. It names no output, so the composition's default
-- applies (a local report under the local operator), and imports only
-- ./Agent.dhall, so a routine agent loads in every composition.
let A = ./Agent.dhall

let turns =
      \(n : Natural) -> Some A.Harness::{ maxModelTurns = Some n }

let skill =
      \(name : Text) ->
      \(directory : Text) ->
        A.Agent::{
        , name
        , behavior = A.Behavior.Skill { path = directory }
        , harness = turns 24
        , identity = Some { principal = "principal_routine" }
        }

let coder =
      \(name : Text) ->
      \(prompt : Text) ->
        A.Agent::{
        , name
        , behavior =
            A.Behavior.CodingAgent
              { provider = A.CodingAgentProvider.ClaudeCode
              , prompt
              , access = A.WorkspaceAccess.EditWorkspace
              , model = None Text
              , effort = None A.CodingAgentEffort
              , deadlineMinutes = 30
              , skills = [] : List Text
              }
        }

let reads = [ "workspace.read" ]

let edits = [ "workspace.read", "workspace.edit", "workspace.git" ]

let daily =
      \(hour : Natural) ->
        A.Trigger.Schedule { cron = "0 ${Natural/show hour} * * *" }

let every = \(cron : Text) -> A.Trigger.Schedule { cron }

-- One declared CLI tool: the executable on PATH and the argument prefixes it
-- may start with (any further words allowed).
let cli =
      \(executable : Text) ->
      \(prefixes : List (List Text)) ->
        A.Tool.CliTool
          A.CliTool::{
          , name = executable
          , executable = A.ExecutableRef.OnPath executable
          , allow =
              List/fold
                (List Text)
                prefixes
                (List A.ArgumentPattern)
                ( \(prefix : List Text) ->
                  \(rest : List A.ArgumentPattern) ->
                    [ A.pattern prefix A.Trailing.AnyTrailing ] # rest
                )
                ([] : List A.ArgumentPattern)
          }

in  { skill, coder, reads, edits, daily, every, turns, cli, Agent = A }
