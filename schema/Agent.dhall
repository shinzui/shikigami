-- schema/Agent.dhall — the canonical C5 agent-definition schema (EP-1, IP-2).
-- It names only kernel vocabulary. Where a run's result goes is an `outputs`
-- list of registered kinds; the Kikan services' kinds have typed helpers in
-- schema/outputs/Kikan.dhall (plan 135, M3).

-- C3's three trigger classes, named to match the spec's C5 vocabulary.
let StreamMatch =
      { verb : Optional Text
      , source : Optional Text
      , subjectType : Optional Text
      , verbs : List Text          -- the seeds' multi-verb match (empty = any verb)
      }

let Trigger =
      < Schedule : { cron : Text }
      | Stream : { match : StreamMatch }
      | Event : { eventType : Text }
      | Manual
      >

-- A vendor coding tool for the CodingAgent arm (EP-2 of MasterPlan 22).
let CodingAgentProvider = < ClaudeCode | Codex >

-- Baikai's capability: Claude's permission mode, Codex's sandbox.
let WorkspaceAccess = < ReadOnly | EditWorkspace | FullAccess >

let CodingAgentEffort =
      < EffortLow | EffortMedium | EffortHigh | EffortXHigh | EffortMax >

-- The behavior union covers all three arms the seeds and the spec need.
let Behavior =
      < ShikumiProgram :
          { task : Text
          , preferEnrichment : Bool
          , grounding : Optional Text
          }
      | Skill : { path : Text }
      | CoordinatingSkill : { path : Text }
      | Flow : { name : Text }
      | CodingAgent :
          { provider : CodingAgentProvider
          , prompt : Text
          , access : WorkspaceAccess
          , model : Optional Text
          , effort : Optional CodingAgentEffort
          , deadlineMinutes : Natural
          , skills : List Text
          }
      | Playbook :
          { bundle : Text
          , provider : CodingAgentProvider
          , access : WorkspaceAccess
          , model : Optional Text
          , effort : Optional CodingAgentEffort
          }
      >

let ProfileRequirement =
      { Type = { profileId : Text, version : Optional Text }
      , default = { version = None Text }
      }

let Identity = { principal : Text }

let MemoryScope = < AgentScope | Shared >

let RecordPolicy = < Always | OnSuccess | Never >

let MemoryPolicy =
      { scope : MemoryScope
      , recallLimit : Natural
      , recordPolicy : RecordPolicy
      }

let defaultMemoryPolicy =
      { scope = MemoryScope.AgentScope
      , recallLimit = 10
      , recordPolicy = RecordPolicy.OnSuccess
      }

let Expertise =
      { key : Text
      , description : Text
      , aliases : List Text
      , evidenceHints : List Text
      }

let RouterConfidence = < RoutingLow | RoutingMedium | RoutingHigh >

let NoMatchPolicy = < ReturnNoMatch | ReturnUnresolved >

let AmbiguousPolicy = < ReturnAmbiguous | SelectAllWithinBound >

let RouterPolicy =
      { maxSelections : Natural
      , minimumConfidence : RouterConfidence
      , onNoMatch : NoMatchPolicy
      , onAmbiguous : AmbiguousPolicy
      }

let Execution = { defaultAlias : Text, permittedAliases : List Text }

let OutputRequirement = < AnyReply | NonemptyReply | JsonFields : List Text >

let Harness =
      { Type =
          { maxModelTurns : Optional Natural
          , outputRepairs : Optional Natural
          , contextBytes : Optional Natural
          , keepRecentMessages : Optional Natural
          , deniedTools : List Text
          , humanTools : List Text
          , permissionSeconds : Optional Natural
          , output : Optional OutputRequirement
          , recoveryAttempts : Optional Natural
          , summaryTokens : Optional Natural
          }
      , default =
          { maxModelTurns = None Natural
          , outputRepairs = None Natural
          , contextBytes = None Natural
          , keepRecentMessages = None Natural
          , deniedTools = [] : List Text
          , humanTools = [] : List Text
          , permissionSeconds = None Natural
          , output = None OutputRequirement
          , recoveryAttempts = None Natural
          , summaryTokens = None Natural
          }
      }

-- Declared CLI tools (EP-3 of MasterPlan 22). Each runs as the overlay
-- cli.<name>; the operator grants the declaration once.
let ExecutableRef = < OnPath : Text | AtPath : Text >

let Trailing = < NoTrailing | AnyTrailing | AtMostTrailing : Natural >

let ArgumentPattern = { prefix : List Text, trailing : Trailing }

let pattern =
      \(prefix : List Text) ->
      \(trailing : Trailing) ->
        { prefix, trailing } : ArgumentPattern

let WorkingDirectoryPolicy = < WorkspaceRoot | WorkspaceSubdirectory : Text >

let OperationClass = < Observation | IdempotentMutation | IrreversibleEmission >

let CallLimits = { timeoutSeconds : Natural, outputBytes : Natural }

let CliTool =
      { Type =
          { name : Text
          , executable : ExecutableRef
          , allow : List ArgumentPattern
          , workingDirectory : WorkingDirectoryPolicy
          , operationClass : OperationClass
          , limits : Optional CallLimits
          }
      , default =
          { workingDirectory = WorkingDirectoryPolicy.WorkspaceRoot
          , operationClass = OperationClass.Observation
          , limits = None CallLimits
          }
      }

-- Approved tools of an MCP server bound in the operator's tools file.
let McpTools = { server : Text, tools : List Text }

let Tool = < CliTool : CliTool.Type | McpTools : McpTools >

-- Where the result goes (EP-8 M2): a registered output kind and its JSON
-- configuration. Helpers: schema/outputs/Local.dhall and, for the Kikan
-- services, schema/outputs/Kikan.dhall. Empty takes the composition's default.
let Output = { kind : Text, config : Text }

let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , delegates : List Text
          , execution : Optional Execution
          , harness : Optional Harness.Type
          , decisionModels : List Text
          , delegationBudget : Optional Natural
          , sanctionedProfile : Optional ProfileRequirement.Type
          , capabilityOverlays : List Text
          , tools : List Tool
          , outputs : List Output
          , identity : Optional Identity
          , memory : MemoryPolicy
          , enabled : Bool
          , expertise : List Expertise
          , routing : Optional RouterPolicy
          }
      , default =
          { description = ""
          , trigger = Trigger.Manual
          , delegates = [] : List Text
          , execution = None Execution
          , harness = None Harness.Type
          , decisionModels = [] : List Text
          , delegationBudget = None Natural
          , sanctionedProfile = None ProfileRequirement.Type
          , capabilityOverlays = [] : List Text
          , tools = [] : List Tool
          , outputs = [] : List Output
          , identity = None Identity
          , memory = defaultMemoryPolicy
          , enabled = True
          , expertise = [] : List Expertise
          , routing = None RouterPolicy
          }
      }

in  { StreamMatch
    , Trigger
    , Behavior
    , CodingAgentProvider
    , WorkspaceAccess
    , CodingAgentEffort
    , ProfileRequirement
    , Identity
    , MemoryScope
    , RecordPolicy
    , MemoryPolicy
    , Expertise
    , RouterConfidence
    , NoMatchPolicy
    , AmbiguousPolicy
    , RouterPolicy
    , Execution
    , Harness
    , OutputRequirement
    , ExecutableRef
    , Trailing
    , ArgumentPattern
    , pattern
    , WorkingDirectoryPolicy
    , OperationClass
    , CallLimits
    , CliTool
    , McpTools
    , Tool
    , Output
    , Agent
    }
