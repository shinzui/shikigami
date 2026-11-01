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
    Trigger (..),
    StreamMatch (..),
    Sink (..),
    SignalType (..),
    Priority (..),
    RecipientFrom (..),
    ProfileRequirement (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import Numeric.Natural (Natural)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.ExpertiseKey (ExpertiseKey)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Attestation.Profile (ProfileId, ProfileVersion)
import Shikigami.Capability.Overlay (CapabilityId)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Policy.Types (HarnessOverrides)
import Shikigami.Execution.Request (ExecutionPolicy)
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

data SignalType
  = Notification
  | Alert
  | Reminder
  | TaskCandidate
  | DigestItem
  | AgentRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Priority = Low | Normal | High | Urgent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RecipientFrom = SubjectOwner | AreaOwner | Actor
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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Behavior
  = Deterministic {rule :: !Text, params :: !(Map Text Text)}
  | ShikumiProgram
      { task :: !(DeclarationCoordinate "task"),
        preferEnrichment :: !Bool,
        grounding :: !(Maybe Text),
        enabledBy :: !(Maybe Text)
      }
  | Skill {path :: !(DeclarationCoordinate "skill-path")}
  | CoordinatingSkill {path :: !(DeclarationCoordinate "skill-path")}
  | Flow {name :: !(DeclarationCoordinate "flow")}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Sink
  = KawaDigest {subjectType :: !(ActivityCoordinate "subject-kind"), verb :: !(ActivityCoordinate "verb")}
  | KizashiSignal
      { source :: !(ActivityCoordinate "source"),
        signalType :: !SignalType,
        priority :: !Priority,
        importance :: !SignalImportance,
        recipientFrom :: !RecipientFrom,
        defaultRecipient :: !(Maybe (DeclarationCoordinate "recipient")),
        intentTemplate :: !Text,
        extraContextTags :: ![Text]
      }
  | ReiAction {intentionId :: !(DeclarationCoordinate "intention"), note :: !Text}
  | DanwaConversation {topic :: !Text}
  | ChannelEgress
      { channel :: !(DeclarationCoordinate "channel"),
        action :: !(DeclarationCoordinate "channel-action"),
        conversationKey :: !(Maybe (DeclarationCoordinate "conversation"))
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

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
    sinks :: ![Sink],
    delegates :: ![AgentName],
    execution :: !(Maybe ExecutionPolicy),
    harness :: !(Maybe HarnessOverrides),
    decisionModels :: ![ModelAlias],
    delegationBudget :: !(Maybe DelegationBudget),
    sanctionedProfile :: !(Maybe ProfileRequirement),
    capabilityOverlays :: ![CapabilityId],
    identity :: !(Maybe IdentityDecl),
    memory :: !MemoryPolicy,
    enabled :: !AgentEnablement,
    expertise :: ![ExpertiseDecl],
    routing :: !(Maybe RouterPolicy)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- Defaulted additions preserve the pre-change journal bytes.
instance ToJSON AgentDecl where
  toJSON declaration = case Aeson.genericToJSON Aeson.defaultOptions declaration of
    Aeson.Object fields ->
      let decisions = if null declaration.decisionModels then KeyMap.delete "decisionModels" fields else fields
          execution = if isNothing declaration.execution then KeyMap.delete "execution" decisions else decisions
          harness = if isNothing declaration.harness then KeyMap.delete "harness" execution else execution
       in Aeson.Object harness
    value -> value

instance FromJSON AgentDecl where
  parseJSON = Aeson.withObject "AgentDecl" \fields ->
    let decisions = if KeyMap.member "decisionModels" fields then fields else KeyMap.insert "decisionModels" (Aeson.toJSON ([] :: [ModelAlias])) fields
        execution = if KeyMap.member "execution" decisions then decisions else KeyMap.insert "execution" Aeson.Null decisions
        harness = if KeyMap.member "harness" execution then execution else KeyMap.insert "harness" Aeson.Null execution
     in Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object harness)
