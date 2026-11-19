-- Playbook bundles (EP-4 of MasterPlan 22). A bundle names its main playbook
-- and holds sibling playbooks; ForEach and RunPlaybook name a sibling. Text
-- fields are templates: {{run.NAME}} reads a top-level string of the run's
-- payload, {{NAME}} a variable bound by an enclosing ForEach. A workspace
-- (CodingAgent, Reflect, ToolIn, ProbeIn) names a repository, empty for the
-- run's own; ToolIn and ProbeIn are Tool and Probe run in that repository.
let Items =
      < Literal : List Text
      | FromPayload : Text
      | FromStep : { step : Text, at : Text, key : Text }
      >

let Step =
      < CodingAgent :
          { id : Text
          , prompt : Text
          , workspace : Text
          , deadlineMinutes : Natural
          , skills : List Text
          }
      | Tool :
          { id : Text, tool : Text, args : List Text, deadlineMinutes : Natural }
      | Probe :
          { id : Text, tool : Text, args : List Text, deadlineMinutes : Natural }
      | ToolIn :
          { id : Text
          , tool : Text
          , args : List Text
          , deadlineMinutes : Natural
          , workspace : Text
          }
      | ProbeIn :
          { id : Text
          , tool : Text
          , args : List Text
          , deadlineMinutes : Natural
          , workspace : Text
          }
      | Approval : { id : Text, prompt : Text }
      | ForEach : { id : Text, items : Items, item : Text, playbook : Text }
      | RunPlaybook : { id : Text, playbook : Text }
      | Reflect : { id : Text, prompt : Text, workspace : Text }
      >

let Playbook = { name : Text, steps : List Step }

let Bundle = { main : Text, playbooks : List Playbook }

let codingAgent =
      \(id : Text) ->
      \(prompt : Text) ->
        Step.CodingAgent
          { id, prompt, workspace = "", deadlineMinutes = 30, skills = [] : List Text }

let approval = \(id : Text) -> \(prompt : Text) -> Step.Approval { id, prompt }

in  { Items, Step, Playbook, Bundle, codingAgent, approval }
