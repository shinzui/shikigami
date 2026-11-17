{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Shikigami.Agent.Decl
  ( module Shikigami.Agent.DeclarationValue,
    module Shikigami.Activity.Coordinate,
    AgentDecl (..),
    IdentityDecl (..),
    MemoryScopeDecl (..),
    RecordPolicy (..),
    MemoryPolicy (..),
    RecallLimit,
    mkRecallLimit,
    recallLimitNatural,
    recallLimitInt,
    DelegationBudget,
    mkDelegationBudget,
    delegationBudgetNatural,
    delegationBudgetInt,
    defaultDelegationBudget,
    defaultMemoryPolicy,
    ExpertiseDecl (..),
    RouterConfidence (..),
    NoMatchPolicy (..),
    AmbiguousPolicy (..),
    RouterPolicy (..),
    Behavior (..),
    codingAgentStepOf,
    codingAgentAccessOf,
    requestedOverlays,
    declaredToolCapabilities,
    Trigger (..),
    StreamMatch (..),
    ProfileRequirement (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import Numeric.Natural (Natural)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.ExpertiseKey (ExpertiseKey)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Attestation.Profile (ProfileId, ProfileVersion)
import Shikigami.Capability.Declared (CliToolDecl (..), ToolDecl, cliCapabilityId, cliTools, mcpRequests)
import Shikigami.Capability.Mcp (McpToolRequest (..), mcpCapabilityId)
import Shikigami.Capability.Overlay (CapabilityId)
import Shikigami.CodingAgent.Types (CodingAgentEffort, CodingAgentPrompt, CodingAgentProvider, CodingAgentStep (..), DeadlineMinutes, SkillDirectory, VendorModelId, WorkspaceAccess)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Policy.Types (HarnessOverrides)
import Shikigami.Execution.Request (ExecutionPolicy)
import Shikigami.Output (OutputDecl)
import Shikigami.Prelude
import Shikigami.Router.SelectionLimit (SelectionLimit)
import Shikigami.Trigger.Schedule (CronExpressionClaim)

data IdentityDecl = IdentityDecl {principal :: !(DeclarationCoordinate "principal")}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data MemoryScopeDecl = AgentScope | Shared
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RecordPolicy = Always | OnSuccess | Never
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

-- | A declaration-level recall bound. Dhall naturals are unbounded, so this
-- value is validated before any conversion to the runtime's 'Int' query bound.
newtype RecallLimit = RecallLimit Natural
  deriving stock (Eq, Ord)

instance Show RecallLimit where
  show = show . recallLimitNatural

mkRecallLimit :: Natural -> Either Text RecallLimit
mkRecallLimit value
  | value < 1 = Left (boundMessage value)
  | value > 1000 = Left (boundMessage value)
  | otherwise = Right (RecallLimit value)
  where
    boundMessage invalid =
      "recallLimit must be between 1 and 1000 inclusive; got "
        <> Text.pack (show invalid)

recallLimitNatural :: RecallLimit -> Natural
recallLimitNatural (RecallLimit value) = value

-- | Total because 'mkRecallLimit' admits only values from 1 through 1000.
recallLimitInt :: RecallLimit -> Int
recallLimitInt = fromIntegral . recallLimitNatural

instance FromDhall RecallLimit where
  autoWith _ =
    let Decoder {extract = extractNatural, expected = expectedNatural} = Dhall.natural
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractNatural expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (mkRecallLimit value),
            expected = expectedNatural
          }

instance ToJSON RecallLimit where
  toJSON = toJSON . recallLimitNatural

instance FromJSON RecallLimit where
  parseJSON value = do
    natural <- parseJSON value
    either (fail . Text.unpack) pure (mkRecallLimit natural)

-- | A root-run-wide bound on distinct descendant workflows. Keeping the Dhall
-- natural bounded here makes conversion to the store's integer column total.
newtype DelegationBudget = DelegationBudget Natural
  deriving stock (Eq, Ord)

instance Show DelegationBudget where
  show = show . delegationBudgetNatural

mkDelegationBudget :: Natural -> Either Text DelegationBudget
mkDelegationBudget value
  | value > 1000 =
      Left
        ( "delegationBudget must be between 0 and 1000 inclusive; got "
            <> Text.pack (show value)
        )
  | otherwise = Right (DelegationBudget value)

delegationBudgetNatural :: DelegationBudget -> Natural
delegationBudgetNatural (DelegationBudget value) = value

-- | Total because 'mkDelegationBudget' admits only values from 0 through 1000.
delegationBudgetInt :: DelegationBudget -> Int
delegationBudgetInt = fromIntegral . delegationBudgetNatural

defaultDelegationBudget :: DelegationBudget
defaultDelegationBudget = DelegationBudget 16

instance FromDhall DelegationBudget where
  autoWith _ =
    let Decoder {extract = extractNatural, expected = expectedNatural} = Dhall.natural
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractNatural expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (mkDelegationBudget value),
            expected = expectedNatural
          }

instance ToJSON DelegationBudget where
  toJSON = toJSON . delegationBudgetNatural

instance FromJSON DelegationBudget where
  parseJSON value = do
    natural <- parseJSON value
    either (fail . Text.unpack) pure (mkDelegationBudget natural)

data MemoryPolicy = MemoryPolicy
  { scope :: !MemoryScopeDecl,
    recallLimit :: !RecallLimit,
    recordPolicy :: !RecordPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

defaultMemoryPolicy :: MemoryPolicy
defaultMemoryPolicy =
  MemoryPolicy
    { scope = AgentScope,
      recallLimit = RecallLimit 10,
      recordPolicy = OnSuccess
    }

data ExpertiseDecl = ExpertiseDecl
  { key :: !ExpertiseKey,
    description :: !Text,
    aliases :: ![Text],
    evidenceHints :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RouterConfidence = RoutingLow | RoutingMedium | RoutingHigh
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data NoMatchPolicy = ReturnNoMatch | ReturnUnresolved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data AmbiguousPolicy = ReturnAmbiguous | SelectAllWithinBound
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RouterPolicy = RouterPolicy
  { maxSelections :: !SelectionLimit,
    minimumConfidence :: !RouterConfidence,
    onNoMatch :: !NoMatchPolicy,
    onAmbiguous :: !AmbiguousPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data StreamMatch = StreamMatch
  { verb :: !(Maybe (ActivityCoordinate "verb")),
    source :: !(Maybe (ActivityCoordinate "source")),
    subjectType :: !(Maybe (ActivityCoordinate "subject-kind")),
    verbs :: ![ActivityCoordinate "verb"]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Trigger
  = Schedule {cron :: !CronExpressionClaim}
  | Stream {match :: !StreamMatch}
  | Event {eventType :: !(DeclarationCoordinate "event-type")}
  | -- | Run only when the operator asks (@shikigami-agent-run@,
    -- @shikigami enqueue-run@); the default of a declaration (EP-8 M2).
    Manual
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Behavior
  = ShikumiProgram
      { task :: !(DeclarationCoordinate "task"),
        preferEnrichment :: !Bool,
        grounding :: !(Maybe Text)
      }
  | Skill {path :: !(DeclarationCoordinate "skill-path")}
  | CoordinatingSkill {path :: !(DeclarationCoordinate "skill-path")}
  | Flow {name :: !(DeclarationCoordinate "flow")}
  | -- | A vendor coding tool (Claude Code or Codex) does the task unattended in
    -- the run's worktree as a durable child step (EP-2 of MasterPlan 22).
    CodingAgent
      { provider :: !CodingAgentProvider,
        prompt :: !CodingAgentPrompt,
        access :: !WorkspaceAccess,
        model :: !(Maybe VendorModelId),
        effort :: !(Maybe CodingAgentEffort),
        deadlineMinutes :: !DeadlineMinutes,
        skills :: ![SkillDirectory]
      }
  | -- | Run a playbook bundle (EP-4 of MasterPlan 22): the bundle file
    -- (absolute, or relative to the declaration) is loaded, checked and
    -- pinned when the run starts, and its coding-agent steps use this
    -- provider, access, model and effort.
    Playbook
      { bundle :: !Text,
        provider :: !CodingAgentProvider,
        access :: !WorkspaceAccess,
        model :: !(Maybe VendorModelId),
        effort :: !(Maybe CodingAgentEffort)
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

-- | The vendor and access of a behavior that runs coding agents.
codingAgentAccessOf :: Behavior -> Maybe (CodingAgentProvider, WorkspaceAccess)
codingAgentAccessOf = \case
  CodingAgent {provider, access} -> Just (provider, access)
  Playbook {provider, access} -> Just (provider, access)
  _ -> Nothing

-- | The step a declaration's @CodingAgent@ arm asks for.
codingAgentStepOf :: Behavior -> Maybe CodingAgentStep
codingAgentStepOf = \case
  CodingAgent {provider, prompt, access, model, effort, deadlineMinutes, skills} ->
    Just CodingAgentStep {provider, prompt, access, model, effort, deadlineMinutes, skills}
  _ -> Nothing

-- | Which sanctioned execution profile an agent run must resolve before it may
-- open a memory session. An absent version means "the one active version" and
-- therefore still fails if the store returns zero or multiple candidates.
data ProfileRequirement = ProfileRequirement
  { profileId :: !ProfileId,
    version :: !(Maybe ProfileVersion)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data AgentDecl = AgentDecl
  { name :: !AgentName,
    description :: !Text,
    trigger :: !Trigger,
    behavior :: !Behavior,
    delegates :: ![AgentName],
    execution :: !(Maybe ExecutionPolicy),
    harness :: !(Maybe HarnessOverrides),
    decisionModels :: ![ModelAlias],
    delegationBudget :: !(Maybe DelegationBudget),
    sanctionedProfile :: !(Maybe ProfileRequirement),
    capabilityOverlays :: ![CapabilityId],
    -- | Declared CLI tools (EP-3). Each is offered as the overlay
    -- @cli.<name>@; omitted from the journal when empty.
    tools :: ![ToolDecl],
    -- | Where the run's result goes (EP-8 M2); empty takes the
    -- composition's default. Omitted from the journal when empty.
    outputs :: ![OutputDecl],
    identity :: !(Maybe IdentityDecl),
    memory :: !MemoryPolicy,
    enabled :: !AgentEnablement,
    expertise :: ![ExpertiseDecl],
    routing :: !(Maybe RouterPolicy)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | Every overlay the declaration requests: its capability overlays, then
-- @cli.<name>@ for each declared CLI tool (EP-3). Resolution, the grant and
-- the behavior environment all read this, never the field alone.
requestedOverlays :: AgentDecl -> [CapabilityId]
requestedOverlays decl@AgentDecl {capabilityOverlays, behavior} = case behavior of
  -- A coding agent runs its declared tools itself, through its gate; a flow
  -- or a playbook runs them as durable steps. None offers them to a model.
  CodingAgent {} -> capabilityOverlays
  Flow {} -> capabilityOverlays
  Playbook {} -> capabilityOverlays
  _ -> capabilityOverlays <> declaredToolCapabilities decl

-- | @cli.<name>@ and @mcp.<server>@ for every declared tool, whatever host
-- uses it; the grant covers them.
declaredToolCapabilities :: AgentDecl -> [CapabilityId]
declaredToolCapabilities AgentDecl {tools} =
  [cliCapabilityId tool.name | tool <- cliTools tools] <> [mcpCapabilityId request.server | request <- mcpRequests tools]

-- Defaulted additions preserve the pre-change journal bytes.
instance ToJSON AgentDecl where
  toJSON declaration = case Aeson.genericToJSON Aeson.defaultOptions declaration of
    Aeson.Object fields ->
      let decisions = if null declaration.decisionModels then KeyMap.delete "decisionModels" fields else fields
          execution = if isNothing declaration.execution then KeyMap.delete "execution" decisions else decisions
          harness = if isNothing declaration.harness then KeyMap.delete "harness" execution else execution
          tools = if null declaration.tools then KeyMap.delete "tools" harness else harness
          outputs = if null declaration.outputs then KeyMap.delete "outputs" tools else tools
       in Aeson.Object outputs
    value -> value

instance FromJSON AgentDecl where
  parseJSON = Aeson.withObject "AgentDecl" \fields ->
    let decisions = if KeyMap.member "decisionModels" fields then fields else KeyMap.insert "decisionModels" (Aeson.toJSON ([] :: [ModelAlias])) fields
        execution = if KeyMap.member "execution" decisions then decisions else KeyMap.insert "execution" Aeson.Null decisions
        harness = if KeyMap.member "harness" execution then execution else KeyMap.insert "harness" Aeson.Null execution
        tools = if KeyMap.member "tools" harness then harness else KeyMap.insert "tools" (Aeson.toJSON ([] :: [ToolDecl])) harness
        outputs = if KeyMap.member "outputs" tools then tools else KeyMap.insert "outputs" (Aeson.toJSON ([] :: [OutputDecl])) tools
     in Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object outputs)
