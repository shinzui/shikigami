{-# LANGUAGE DataKinds #-}

-- | Pure admission rules. Cost is always integer millionths of one USD;
-- counters and ceilings use integers, never floating point arithmetic.
module Shikigami.Execution.Resources where

import Data.Aeson (FromJSONKey, ToJSONKey)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shikigami.Execution.Counter
import Shikigami.Execution.Identity
import Shikigami.Execution.Quantity
import Shikigami.Prelude
import Shikigami.StateRevision

data Dimension = ActiveWork | LifetimeDescendants | ModelAttempts | ToolAttempts | Tokens | CostMicroUsd
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

type Quantities = Map Dimension ResourceAmount

-- | Absence is denial. Unbounded capacity must be explicitly admitted by an
-- operator, including dimensions whose usage a transport cannot measure.
data Limit = Limited !ResourceAmount | ExplicitlyUnbounded
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

type Limits = Map Dimension Limit

data Envelope = Envelope
  { limits :: !Limits,
    cutoff :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Usage = Usage
  { settled :: !Quantities,
    held :: !Quantities
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

emptyUsage :: Usage
emptyUsage = Usage Map.empty Map.empty

data Root = Root
  { envelope :: !Envelope,
    revision :: !(StateRevision "execution-root"),
    cancelled :: !Bool,
    activeLimit :: !(Maybe ResourceAmount),
    overage :: !Bool,
    active :: !(AttemptCount "root-active"),
    unknown :: !(AttemptCount "root-unknown"),
    known :: !Quantities,
    usage :: !Usage
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Allocations are exclusive, finite sub-envelopes. Their entire capacity is
-- held in the parent; work spends within that capacity, not a second root.
data Allocation = Allocation
  { parent :: !(Maybe AllocationId),
    admitted :: !Envelope,
    current :: !Envelope,
    usage :: !Usage
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OperationKind = ModelOperation | ToolOperation | ChildOperation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OperationRequest = OperationRequest
  { operationId :: !OperationId,
    allocationId :: !(Maybe AllocationId),
    kind :: !OperationKind,
    quantities :: !Quantities,
    fingerprint :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Enforced ceilings are a contract with the dispatcher: it must apply the
-- ceiling to the actual request. Unknown policy cannot satisfy a finite cap.
data UsagePolicy = EnforcedCeiling | AdmittedUnknownUsage
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AttemptRequest = AttemptRequest
  { attemptId :: !AttemptId,
    operationId :: !OperationId,
    quantities :: !Quantities,
    policy :: !UsagePolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Settlement
  = KnownUsage !Quantities
  | UnknownUsage !Text
  | -- | A terminal transport is known to have stopped, but some billing facts
    -- remain unknown. Release active work; hold only uncertain usage ceilings.
    PartialUsage !Quantities ![Dimension] !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Attempt = Attempt
  { request :: !AttemptRequest,
    outcome :: !(Maybe Settlement)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Admission = Accepted | AlreadyAccepted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResourceError
  = RootMissing
  | IdentityConflict
  | RevisionConflict
  | ResourceExhausted !Dimension
  | DimensionNotAdmitted !Dimension
  | CutoffReached
  | RootCancelled
  | OverageRecorded
  | AllocationMissing
  | OperationMissing
  | AttemptMissing
  | SettlementConflict
  | InvalidResourceRequest !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Amount admission happens once in ResourceAmount construction/JSON decoding.
-- The vector operations additionally check aggregate overflow and underflow.
refineAmounts :: Map Dimension Integer -> Either ResourceError Quantities
refineAmounts = traverse (either (Left . InvalidResourceRequest) Right . parseResourceAmount)

add :: Quantities -> Quantities -> Either ResourceError Quantities
add left right = refineAmounts (Map.unionWith (+) (amountUnits <$> left) (amountUnits <$> right))

subtractAmounts :: Quantities -> Quantities -> Either ResourceError Quantities
subtractAmounts left right = refineAmounts (Map.unionWith (+) (amountUnits <$> left) (negate . amountUnits <$> right))

occupied :: Usage -> Either ResourceError Quantities
occupied Usage {settled, held} = add settled held

admit :: Limits -> Usage -> Quantities -> Either ResourceError Usage
admit limits usage amounts = do
  -- Keep the existing refusal order: dimension/finite limits precede the
  -- int64 overflow check. Signed/unbounded intermediates stay local here.
  let next = Map.unionsWith (+) [amountUnits <$> usage.settled, amountUnits <$> usage.held, amountUnits <$> amounts]
  forM_ (Map.toList amounts) \(dimension, amount) -> when (amount > zeroAmount) do
    case Map.lookup dimension limits of
      Nothing -> Left (DimensionNotAdmitted dimension)
      Just ExplicitlyUnbounded -> pure ()
      Just (Limited maximumAmount) ->
        when (Map.findWithDefault 0 dimension next > amountUnits maximumAmount) (Left (ResourceExhausted dimension))
  _ <- refineAmounts next
  held <- add usage.held amounts
  pure (Usage usage.settled held)

checkRoot :: UTCTime -> StateRevision "execution-root" -> Root -> Either ResourceError ()
checkRoot now expected root = do
  when (expected /= root.revision) (Left RevisionConflict)
  when root.cancelled (Left RootCancelled)
  when root.overage (Left OverageRecorded)
  when (now >= root.envelope.cutoff) (Left CutoffReached)

effectiveLimits :: Root -> Limits
effectiveLimits root = case root.activeLimit of
  Nothing -> root.envelope.limits
  Just n -> Map.insert ActiveWork (Limited n) root.envelope.limits

validateOperation :: OperationRequest -> Either ResourceError ()
validateOperation request = do
  let OperationId key = request.operationId
  validateKey key
  validateKey request.fingerprint
  case request.kind of
    ChildOperation -> unless (request.quantities == Map.singleton LifetimeDescendants oneAmount) invalid
    _ -> unless (Map.null request.quantities) invalid
  where
    invalid = Left (InvalidResourceRequest "only child operations reserve lifetime descendants; attempts reserve actual work")

validateKey :: Text -> Either ResourceError ()
validateKey key = unless (not (Text.null key) && Text.length key <= 256) (Left (InvalidResourceRequest "identity/fingerprint must contain 1..256 characters"))

validateAttempt :: Limits -> OperationRequest -> AttemptRequest -> Either ResourceError ()
validateAttempt limits operation request = do
  let AttemptId key = request.attemptId
      amounts = request.quantities
      count = if operation.kind == ModelOperation then ModelAttempts else ToolAttempts
      forbidden = if operation.kind == ModelOperation then ToolAttempts else ModelAttempts
  validateKey key
  when (operation.kind == ChildOperation || request.operationId /= operation.operationId) invalid
  unless (Map.lookup count amounts == Just oneAmount && Map.lookup ActiveWork amounts == Just oneAmount) invalid
  when (Map.findWithDefault zeroAmount forbidden amounts /= zeroAmount || Map.findWithDefault zeroAmount LifetimeDescendants amounts /= zeroAmount) invalid
  forM_ [Tokens, CostMicroUsd] \dimension -> case Map.lookup dimension limits of
    Nothing | operation.kind == ModelOperation || request.policy == AdmittedUnknownUsage -> Left (DimensionNotAdmitted dimension)
    Just (Limited _) ->
      unless (request.policy == EnforcedCeiling && Map.member dimension amounts) (Left (InvalidResourceRequest "finite token/cost limits require a reserved enforced request ceiling"))
    _ -> pure ()
  where
    invalid = Left (InvalidResourceRequest "attempt must reserve one active slot and one matching transport attempt")

-- | Counters remain spent even for failed transports. Only known completion
-- releases active work and replaces token/cost ceilings with measured usage.
settleUsage :: Quantities -> Quantities -> Usage -> Either ResourceError Usage
settleUsage reservation measured usage = do
  unless (all (`elem` [Tokens, CostMicroUsd]) (Map.keys measured)) (Left (InvalidResourceRequest "only token and cost measurements may be supplied"))
  let required = Map.filterWithKey (\key _ -> key `elem` [Tokens, CostMicroUsd]) reservation
  unless (all (`Map.member` measured) (Map.keys required)) (Left (InvalidResourceRequest "each reserved measurable dimension needs a result"))
  let counters = Map.filterWithKey (\key _ -> key `elem` [ModelAttempts, ToolAttempts]) reservation
  recorded <- add counters measured >>= add usage.settled
  held <- subtractAmounts usage.held reservation
  let next = Usage recorded held
  _ <- occupied next
  pure next
