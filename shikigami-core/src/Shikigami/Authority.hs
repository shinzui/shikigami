{-# LANGUAGE DataKinds #-}

-- | The kernel's action vocabulary and its authority port.
--
-- Every external action a run performs is named by a kernel-owned 'Action'
-- and decided, immediately before the effect, by exactly one 'Authority'
-- (ADR-36, restated over this type by ADR-123). An authority fails closed: a
-- 'Left' is a refusal, and 'denyAll' is the value when nothing is composed.
--
-- Service authorizers such as Kikan-En are adapters of this port
-- ("Shikigami.Authority.KikanEn"). They map a kernel action onto their own
-- vocabulary and refuse what they cannot map.
--
-- 'recorded' is how a composition root installs an authority: it appends one
-- @authority.decided@ event to the action record for every decision and turns
-- a failed append into a refusal, so an unrecorded action never proceeds.
--
-- The sum is closed over what the kernel executes today (ADR-1). A plan that
-- adds a kernel effect adds its constructor here in the same change.
module Shikigami.Authority
  ( -- * Principals
    Principal,

    -- * Actions
    Action (..),
    CapabilityOperation (..),
    CapabilityTarget,
    mkCapabilityTarget,
    capabilityTargetId,
    capabilityTargetRevision,
    ToolName,
    mkToolName,
    toolNameText,
    OutputKind,
    mkOutputKind,
    outputKindText,
    OutputTarget,
    mkOutputTarget,
    outputTargetSegments,
    actionTag,
    actionResource,
    connectProviderAction,
    invokeToolAction,

    -- * The port
    Authority,
    authority,
    AuthorityFailure (..),
    authorityFailureDetail,
    authorityFailureLabel,
    Decision (..),
    DecisionSource (..),
    decisionSourceText,
    denyAll,
    allowAllForTests,

    -- * Recording
    recorded,
    recordedIn,
    observeDecisions,
    scopeToRun,
    decidedKind,
    decisionEntry,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Char (isAsciiLower, isControl, isDigit, isSpace)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import GHC.Records (HasField (..))
import Hasql.Pool (Pool)
import Keiro.Workflow (WorkflowId)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding (at, matching, (.=))
import Shikigami.Record
  ( ActionRecord (..),
    RecordEntry,
    RecordEvent (..),
    RecordKind,
    TierLabel,
    mkRecordEntry,
    mkRecordKind,
    observedRecord,
    postgresRecord,
    recordErrorText,
    unspecifiedTier,
  )
import Shikigami.Telemetry.Metrics (ShikigamiMetrics)

-- | The verified principal an action is decided for: the existing checked
-- declaration coordinate.
type Principal = DeclarationCoordinate "principal"

-- | One external action, in the kernel's own vocabulary.
data Action
  = -- | Connect to a capability provider or invoke one of its tools. The
    -- kernel's own effects (workspace, worker sessions, objectives) are
    -- capability tools of the reserved @shikigami.*@ capabilities.
    UseCapability !CapabilityOperation !CapabilityTarget
  | -- | Deliver a run's result through an output of the given kind.
    EmitOutput !OutputKind !OutputTarget
  deriving stock (Eq, Ord, Show)

data CapabilityOperation
  = ConnectProvider
  | InvokeTool !ToolName
  deriving stock (Eq, Ord, Show)

-- | A capability provider at an exact revision.
data CapabilityTarget = CapabilityTarget !Text !Text
  deriving stock (Eq, Ord, Show)

-- | The capability id matches @[a-z][a-z0-9.-]*@ without consecutive dots;
-- the revision is opaque without whitespace, control characters or @\@/:#@.
-- Both are at most 128 characters.
mkCapabilityTarget :: Text -> Text -> Either Text CapabilityTarget
mkCapabilityTarget capability revision =
  CapabilityTarget <$> validCapabilityId capability <*> validOpaque "capability revision" "@/:#" revision

capabilityTargetId :: CapabilityTarget -> Text
capabilityTargetId (CapabilityTarget capability _) = capability

capabilityTargetRevision :: CapabilityTarget -> Text
capabilityTargetRevision (CapabilityTarget _ revision) = revision

newtype ToolName = ToolName Text
  deriving stock (Eq, Ord, Show)

mkToolName :: Text -> Either Text ToolName
mkToolName = fmap ToolName . validOpaque "tool name" "@/:#"

toolNameText :: ToolName -> Text
toolNameText (ToolName value) = value

-- | A checked dotted output kind such as @kizashi.signal@ or @local.report@:
-- @[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+@, at most 64 characters. Adapters own
-- their kinds.
newtype OutputKind = OutputKind Text
  deriving stock (Eq, Ord, Show)

mkOutputKind :: Text -> Either Text OutputKind
mkOutputKind value = OutputKind value <$ mkRecordKind value

outputKindText :: OutputKind -> Text
outputKindText (OutputKind value) = value

-- | Where an output is delivered, as one to four opaque segments (for
-- example a recipient, or a channel provider and conversation). Each segment
-- is 1 to 128 characters without whitespace, control characters or @#@.
newtype OutputTarget = OutputTarget (NonEmpty Text)
  deriving stock (Eq, Ord, Show)

mkOutputTarget :: NonEmpty Text -> Either Text OutputTarget
mkOutputTarget segments
  | NonEmpty.length segments > 4 = Left "output target has at most four segments"
  | otherwise = OutputTarget <$> traverse (validOpaque "output target segment" "#") segments

outputTargetSegments :: OutputTarget -> NonEmpty Text
outputTargetSegments (OutputTarget segments) = segments

-- | Connect to a capability provider at an exact revision.
connectProviderAction :: Text -> Text -> Either Text Action
connectProviderAction capability revision = UseCapability ConnectProvider <$> mkCapabilityTarget capability revision

-- | Invoke one tool of a capability provider at an exact revision.
invokeToolAction :: Text -> Text -> Text -> Either Text Action
invokeToolAction capability revision tool =
  UseCapability <$> (InvokeTool <$> mkToolName tool) <*> mkCapabilityTarget capability revision

-- | The stable tag recorded for an action.
actionTag :: Action -> Text
actionTag = \case
  UseCapability {} -> "use_capability"
  EmitOutput {} -> "emit_output"

-- | A canonical, bounded rendering of what the action touches. It never
-- contains tool input or content.
actionResource :: Action -> Text
actionResource = \case
  UseCapability ConnectProvider target -> "capability_provider:" <> providerText target
  UseCapability (InvokeTool tool) target -> "capability_tool:" <> providerText target <> "/" <> toolNameText tool
  EmitOutput kind target -> outputKindText kind <> ":" <> Text.intercalate "/" (NonEmpty.toList (outputTargetSegments target))
  where
    providerText target = capabilityTargetId target <> "@" <> capabilityTargetRevision target

operationLabel :: Action -> Maybe Text
operationLabel = \case
  UseCapability ConnectProvider _ -> Just "connect"
  UseCapability InvokeTool {} _ -> Just "invoke"
  EmitOutput {} -> Nothing

data AuthorityFailure
  = PolicyDenied !Text
  | AuthorityUnavailable !Text
  | ProofRejected !Text
  | InvalidCoordinates !Text
  deriving stock (Eq, Show)

authorityFailureDetail :: AuthorityFailure -> Text
authorityFailureDetail = \case
  PolicyDenied detail -> "denied: " <> boundedBehaviorDetail detail
  AuthorityUnavailable detail -> "unavailable: " <> boundedBehaviorDetail detail
  ProofRejected detail -> "proof rejected: " <> boundedBehaviorDetail detail
  InvalidCoordinates detail -> "invalid coordinates: " <> boundedBehaviorDetail detail

authorityFailureLabel :: AuthorityFailure -> Text
authorityFailureLabel = \case
  PolicyDenied {} -> "denied"
  AuthorityUnavailable {} -> "unavailable"
  ProofRejected {} -> "proof_rejected"
  InvalidCoordinates {} -> "invalid"

-- | Bounded, non-secret coordinates of an allow. A service proof never
-- appears here.
data Decision = Decision
  { action :: !Action,
    reference :: !Text,
    expiresAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

-- | Who decides for an authority.
data DecisionSource
  = DecidedByOperator
  | DecidedByService !Text
  | DecidedByFixture
  | -- | Nothing is composed; every action is refused.
    NoAuthority
  deriving stock (Eq, Show)

decisionSourceText :: DecisionSource -> Text
decisionSourceText = \case
  DecidedByOperator -> "operator"
  DecidedByService service -> "service:" <> service
  DecidedByFixture -> "fixture"
  NoAuthority -> "none"

-- | Run coordinates attached to recorded decisions.
data RunContext = RunContext
  { run :: !(Maybe WorkflowId),
    agent :: !(Maybe AgentName)
  }

-- | The authority port. The constructor is private: build one with
-- 'authority', install it with 'recorded', and scope it to a run with
-- 'scopeToRun'. Read it with @authority.decide@ and @authority.source@.
data Authority = Authority
  { origin :: !DecisionSource,
    decideIn :: !(RunContext -> Principal -> Action -> IO (Either AuthorityFailure Decision)),
    context :: !RunContext
  }

instance HasField "decide" Authority (Principal -> Action -> IO (Either AuthorityFailure Decision)) where
  getField Authority {decideIn, context} = decideIn context

instance HasField "source" Authority DecisionSource where
  getField Authority {origin} = origin

-- | An authority from its decision function.
authority :: DecisionSource -> (Principal -> Action -> IO (Either AuthorityFailure Decision)) -> Authority
authority origin decideFn =
  Authority {origin, decideIn = const decideFn, context = RunContext {run = Nothing, agent = Nothing}}

-- | The value when nothing is composed. It never falls back to a grant table
-- or to declaration authority.
denyAll :: Authority
denyAll = authority NoAuthority \_ _ -> pure (Left (AuthorityUnavailable "per-action authorization is not configured"))

-- | Allow everything. Focused tests only; no composition root uses it.
allowAllForTests :: Authority
allowAllForTests =
  authority DecidedByFixture \_ requested ->
    pure (Right Decision {action = requested, reference = "request_test", expiresAt = Nothing})

-- | Decisions made through the returned authority carry this run (absent
-- for a database-free one-off) and agent in the record. Scoping an
-- unrecorded authority changes nothing.
scopeToRun :: Maybe WorkflowId -> AgentName -> Authority -> Authority
scopeToRun runId agentName current =
  current {context = RunContext {run = runId, agent = Just agentName}}

decidedKind :: RecordKind
decidedKind = either (error . Text.unpack) id (mkRecordKind "authority.decided")

-- | Install an authority: every decision is appended to the record before
-- the result is returned, and a failed append is a refusal (K3).
recorded :: ActionRecord -> TierLabel -> Authority -> Authority
recorded ActionRecord {append} tier inner@Authority {origin, decideIn} =
  inner
    { decideIn = \ctx@RunContext {run, agent} principal requested -> do
        result <- decideIn ctx principal requested
        at <- getCurrentTime
        let failRecord = Left (AuthorityUnavailable "action record unavailable")
        case decisionEntry origin requested result of
          Left _ -> pure failRecord
          Right entry ->
            append RecordEvent {at, run, principal = declarationCoordinateText principal, tier, agent, entry} <&> \case
              Left problem -> Left (AuthorityUnavailable ("action record unavailable (" <> recordErrorText problem <> ")"))
              Right () -> result
    }

-- | Install an authority over the PostgreSQL action record: the composition
-- root of every durable process uses this.
recordedIn :: Log.Logger -> Maybe ShikigamiMetrics -> Pool -> Authority -> Authority
recordedIn logger metrics pool = recorded (observedRecord logger metrics (postgresRecord pool)) unspecifiedTier

-- | Run an observer after every decision, without changing it. Evidence
-- fixtures use this to write their own trace beside the action record.
observeDecisions :: (Principal -> Action -> Either AuthorityFailure Decision -> IO ()) -> Authority -> Authority
observeDecisions observer inner@Authority {decideIn} =
  inner
    { decideIn = \ctx principal requested -> do
        result <- decideIn ctx principal requested
        observer principal requested result
        pure result
    }

-- | The @authority.decided@ entry for one decision.
decisionEntry :: DecisionSource -> Action -> Either AuthorityFailure Decision -> Either Text RecordEntry
decisionEntry origin requested result =
  either (Left . recordErrorText) Right $
    mkRecordEntry
      decidedKind
      ( Aeson.object
          ( [ "action" .= actionTag requested,
              "operation" .= operationLabel requested,
              "resource" .= actionResource requested,
              "decidedBy" .= decisionSourceText origin
            ]
              <> case result of
                Right Decision {reference, expiresAt} ->
                  ["decision" .= ("allowed" :: Text), "reference" .= reference, "expiresAt" .= expiresAt]
                Left failure ->
                  ["decision" .= authorityFailureLabel failure, "detail" .= authorityFailureDetail failure]
          )
      )

validCapabilityId :: Text -> Either Text Text
validCapabilityId value
  | Text.length value > 128 = Left "capability id must be at most 128 characters"
  | Just (first', rest) <- Text.uncons value,
    isAsciiLower first',
    Text.all (\c -> isAsciiLower c || isDigit c || c == '.' || c == '-') rest,
    not (".." `Text.isInfixOf` value) =
      Right value
  | otherwise = Left "capability id must match [a-z][a-z0-9.-]* without consecutive dots"

validOpaque :: Text -> Text -> Text -> Either Text Text
validOpaque label reserved value
  | Text.null value = Left (label <> " must not be empty")
  | Text.length value > 128 = Left (label <> " must be at most 128 characters")
  | Text.any (\c -> isSpace c || isControl c) value = Left (label <> " must not contain whitespace or control characters")
  | Just offending <- Text.find (`Text.elem` reserved) value = Left (label <> " must not contain " <> Text.singleton offending)
  | otherwise = Right value
