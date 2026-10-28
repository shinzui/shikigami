-- | Pure admission rules. Cost is always integer millionths of one USD;
-- counters and ceilings use integers, never floating point arithmetic.
module Shikigami.Execution.Resources where

import Data.Aeson (FromJSONKey, ToJSONKey)
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shikigami.Execution.Identity
import Shikigami.Prelude

data Dimension = ActiveWork | LifetimeDescendants | ModelAttempts | ToolAttempts | Tokens | CostMicroUsd
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

type Quantities = Map Dimension Integer

-- | Absence is denial. Unbounded capacity must be explicitly admitted by an
-- operator, including dimensions whose usage a transport cannot measure.
data Limit = Limited !Integer | ExplicitlyUnbounded
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
    revision :: !Integer,
    cancelled :: !Bool,
    activeLimit :: !(Maybe Integer),
    overage :: !Bool,
    active :: !Integer,
    unknown :: !Integer,
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

validQuantity :: Integer -> Bool
validQuantity n = n >= 0 && n <= toInteger (maxBound :: Int64)

validateQuantities :: Quantities -> Either ResourceError ()
validateQuantities amounts =
  unless (all validQuantity amounts) (Left (InvalidResourceRequest "quantities must fit nonnegative int64 units"))

validateEnvelope :: Envelope -> Either ResourceError ()
validateEnvelope Envelope {limits} =
  traverse_ check (Map.elems limits)
  where
    check ExplicitlyUnbounded = Right ()
    check (Limited n) = unless (validQuantity n) (Left (InvalidResourceRequest "invalid resource limit"))

add :: Quantities -> Quantities -> Quantities
add = Map.unionWith (+)

subtractAmounts :: Quantities -> Quantities -> Quantities
subtractAmounts a b = add a (negate <$> b)

occupied :: Usage -> Quantities
occupied Usage {settled, held} = add settled held

admit :: Limits -> Usage -> Quantities -> Either ResourceError Usage
admit limits usage amounts = do
  validateQuantities amounts
  let next = add (occupied usage) amounts
  forM_ (Map.toList amounts) \(dimension, amount) -> when (amount > 0) do
    case Map.lookup dimension limits of
      Nothing -> Left (DimensionNotAdmitted dimension)
      Just ExplicitlyUnbounded -> pure ()
      Just (Limited maximumAmount) ->
        when (Map.findWithDefault 0 dimension next > maximumAmount) (Left (ResourceExhausted dimension))
  validateQuantities next
  pure (Usage usage.settled (add usage.held amounts))

checkRoot :: UTCTime -> Integer -> Root -> Either ResourceError ()
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
  validateQuantities request.quantities
  case request.kind of
    ChildOperation -> unless (request.quantities == Map.singleton LifetimeDescendants 1) invalid
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
  validateQuantities amounts
  when (operation.kind == ChildOperation || request.operationId /= operation.operationId) invalid
  unless (Map.lookup count amounts == Just 1 && Map.lookup ActiveWork amounts == Just 1) invalid
  when (Map.findWithDefault 0 forbidden amounts /= 0 || Map.findWithDefault 0 LifetimeDescendants amounts /= 0) invalid
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
  validateQuantities measured
  unless (all (`elem` [Tokens, CostMicroUsd]) (Map.keys measured)) (Left (InvalidResourceRequest "only token and cost measurements may be supplied"))
  let required = Map.filterWithKey (\key _ -> key `elem` [Tokens, CostMicroUsd]) reservation
  unless (all (`Map.member` measured) (Map.keys required)) (Left (InvalidResourceRequest "each reserved measurable dimension needs a result"))
  let counters = Map.filterWithKey (\key _ -> key `elem` [ModelAttempts, ToolAttempts]) reservation
      next = Usage (add usage.settled (add counters measured)) (subtractAmounts usage.held reservation)
  validateQuantities next.held
  validateQuantities (occupied next)
  pure next
