{-# LANGUAGE DataKinds #-}

-- | Standing policies: the one explicit way past a person. A policy is a durable
-- row installed by the configured local operator and read fresh under a row lock
-- at every admission, so revocation stops the next admission at once while work
-- already admitted continues. No declaration can create one, and it grants no
-- workspace, sink or tool authority.
module Shikigami.Initiative.Policy
  ( PolicyInput (..),
    StandingPolicy,
    PolicyFacts (..),
    Revocation (..),
    policyFacts,
    PolicyDigest,
    policyDigestText,
    policyDigestFor,
    PolicyView (..),
    policyView,
    PolicyRefusal (..),
    policyRefusalText,
    PolicyContext (..),
    validatePolicy,
    installPolicy,
    revokePolicy,
    listPolicies,
    readPolicy,
    coveringPolicies,
    Reservation (..),
    AdmissionRefusal (..),
    admissionRefusalText,
    reserveAdmission,
    readReservation,
    AdmissionStage (..),
    recordAdmissionStage,
    AdmissionView (..),
    readAdmission,
    listAdmissions,
    livePolicies,
    PolicyUsage (..),
    policyUsage,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5, contrazip7)
import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..))
import Shikigami.Agent.DeclarationValue (agentEnabled, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Agent.Principal qualified as Principal
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Execution.Identity (ExecutionRootId, executionRootIdText)
import Shikigami.Execution.Quantity (ResourceAmount, amountUnits)
import Shikigami.Execution.Resources (Dimension (..), Envelope (..), Limit (..), Limits)
import Shikigami.Initiative.Settings (parseLimits, renderLimits)
import Shikigami.Initiative.Types
import Shikigami.Objective.Keys (OperatorId, operatorIdText, parseOperatorId)
import Shikigami.Objective.Store (creationAllowed)
import Shikigami.Objective.Types (AccessPrincipal (RecordedAgent), ObjectiveId, ObjectiveSettings, objectiveIdText)
import Shikigami.Repository (RepositoryId, repositoryIdText)
import Shikigami.StateRevision (StateRevision, advanceRevision, initialRevision, parseRevision, revisionNumber)

-- | The operator's document. A proposal for a policy, not a policy.
data PolicyInput = PolicyInput
  { principal :: !AgentPrincipal,
    sources :: !(NonEmpty SourceKind),
    repositories :: !(NonEmpty RepositoryId),
    actionClasses :: !(NonEmpty ActionClass),
    coordinator :: !AgentName,
    perObjective :: !Limits,
    objectiveWindow :: !(Duration "initiative-objective"),
    total :: !Limits,
    admissionsPerWindow :: !(InitiativeLimit "admissionsPerWindow"),
    window :: !(Duration "initiative-window"),
    expiresAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PolicyInput where
  toJSON input =
    object
      [ "principal" .= principalText input.principal,
        "sources" .= input.sources,
        "repositories" .= input.repositories,
        "actionClasses" .= input.actionClasses,
        "coordinator" .= input.coordinator,
        "perObjective" .= renderLimits input.perObjective,
        "objectiveWindow" .= input.objectiveWindow,
        "total" .= renderLimits input.total,
        "admissionsPerWindow" .= input.admissionsPerWindow,
        "window" .= input.window,
        "expiresAt" .= input.expiresAt
      ]

instance FromJSON PolicyInput where
  parseJSON = withObject "standing policy" \fields -> do
    unless (all (`elem` accepted) (KeyMap.keys fields)) (fail "unknown standing policy field")
    principal <- fields .: "principal" >>= either (fail . Text.unpack) pure . mkAgentPrincipal
    sources <- fields .: "sources"
    repositories <- fields .: "repositories"
    actionClasses <- fields .: "actionClasses"
    coordinator <- fields .: "coordinator"
    perObjective <- fields .: "perObjective" >>= parseLimits
    objectiveWindow <- fields .: "objectiveWindow"
    total <- fields .: "total" >>= parseLimits
    admissionsPerWindow <- fields .: "admissionsPerWindow"
    window <- fields .: "window"
    expiresAt <- fields .: "expiresAt"
    unless (durationTime objectiveWindow > 0 && durationTime window > 0) (fail "standing policy durations must be positive")
    pure PolicyInput {principal, sources, repositories, actionClasses, coordinator, perObjective, objectiveWindow, total, admissionsPerWindow, window, expiresAt}
    where
      accepted = ["principal", "sources", "repositories", "actionClasses", "coordinator", "perObjective", "objectiveWindow", "total", "admissionsPerWindow", "window", "expiresAt"]

newtype PolicyDigest = PolicyDigest Text
  deriving stock (Eq, Ord, Show)

policyDigestText :: PolicyDigest -> Text
policyDigestText (PolicyDigest value) = value

policyDigestFor :: PolicyInput -> PolicyDigest
policyDigestFor input = PolicyDigest (versionedDigest "shikigami.standing-policy/1" (toJSON input))

instance ToJSON PolicyDigest where toJSON = toJSON . policyDigestText

instance FromJSON PolicyDigest where
  parseJSON = withText "policy digest" (pure . PolicyDigest)

data Revocation = Revocation {by :: !OperatorId, at :: !UTCTime}
  deriving stock (Eq, Show)

data PolicyFacts = PolicyFacts
  { policyId :: !StandingPolicyId,
    input :: !PolicyInput,
    digest :: !PolicyDigest,
    installedBy :: !OperatorId,
    installedAt :: !UTCTime,
    revoked :: !(Maybe Revocation),
    revision :: !(StateRevision "standing-policy")
  }
  deriving stock (Eq, Show)

-- | Sealed: minted only by 'installPolicy' and by reading a stored row.
newtype StandingPolicy = StandingPolicy PolicyFacts
  deriving stock (Eq, Show)

policyFacts :: StandingPolicy -> PolicyFacts
policyFacts (StandingPolicy facts) = facts

data PolicyView = PolicyView
  { policyId :: !Text,
    principal :: !Text,
    sources :: ![SourceKind],
    repositories :: ![Text],
    actionClasses :: ![ActionClass],
    coordinator :: !Text,
    digest :: !Text,
    installedBy :: !Text,
    installedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    revokedBy :: !(Maybe Text),
    revokedAt :: !(Maybe UTCTime),
    revision :: !Integer,
    state :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Live, revoked or expired at the instant the view is taken.
policyView :: UTCTime -> StandingPolicy -> PolicyView
policyView now policy =
  PolicyView
    { policyId = standingPolicyIdText facts.policyId,
      principal = principalText facts.input.principal,
      sources = toList facts.input.sources,
      repositories = map repositoryIdText (toList facts.input.repositories),
      actionClasses = toList facts.input.actionClasses,
      coordinator = agentNameText facts.input.coordinator,
      digest = policyDigestText facts.digest,
      installedBy = operatorIdText facts.installedBy,
      installedAt = facts.installedAt,
      expiresAt = facts.input.expiresAt,
      revokedBy = operatorIdText . (.by) <$> facts.revoked,
      revokedAt = (.at) <$> facts.revoked,
      revision = revisionNumber facts.revision,
      state
    }
  where
    facts = policyFacts policy
    state
      | isJust facts.revoked = "revoked"
      | now >= facts.input.expiresAt = "expired"
      | otherwise = "live"

data PolicyRefusal
  = UnknownPrincipal
  | PrincipalCannotCreateObjectives
  | UnknownRepository !RepositoryId
  | UnknownCoordinator !AgentName
  | CoordinatorNotCoordinating !AgentName
  | CoordinatorHasNoIdentity
  | EnvelopeDeniesModelAttempts
  | TotalBelowPerObjective !Dimension
  | ExpiryTooFar
  | ExpiryInPast
  | PolicyMissing
  | PolicyRevoked
  | PolicyExpired
  | PolicyConflict
  | PolicyUnreadable
  deriving stock (Eq, Show)

instance ToJSON PolicyRefusal where
  toJSON = toJSON . policyRefusalText

-- | Stable and bounded. An identifier inside a refusal is the operator's own input.
policyRefusalText :: PolicyRefusal -> Text
policyRefusalText = \case
  UnknownPrincipal -> "unknown principal"
  PrincipalCannotCreateObjectives -> "principal cannot create objectives"
  UnknownRepository repository -> "unknown repository: " <> repositoryIdText repository
  UnknownCoordinator coordinator -> "unknown coordinator: " <> agentNameText coordinator
  CoordinatorNotCoordinating coordinator -> "coordinator cannot coordinate: " <> agentNameText coordinator
  CoordinatorHasNoIdentity -> "coordinator declares no identity"
  EnvelopeDeniesModelAttempts -> "per-objective envelope must name ActiveWork, ModelAttempts, Tokens and an unbounded CostMicroUsd"
  TotalBelowPerObjective dimension -> "total is below the per-objective envelope for " <> Text.pack (show dimension)
  ExpiryTooFar -> "expiry exceeds the maximum policy lifetime"
  ExpiryInPast -> "expiry is in the past"
  PolicyMissing -> "policy is missing"
  PolicyRevoked -> "policy is revoked"
  PolicyExpired -> "policy has expired"
  PolicyConflict -> "policy revision conflict"
  PolicyUnreadable -> "policy row is unreadable"

-- | What a document is checked against. The operator command builds it from
-- configuration; the principal check closes over the directory's current view.
data PolicyContext = PolicyContext
  { principalActive :: !(AgentPrincipal -> Bool),
    objectives :: !ObjectiveSettings,
    catalog :: ![RepositoryId],
    declarations :: ![AgentDecl],
    now :: !UTCTime,
    maximumLifetime :: !(Duration "initiative-policy-lifetime")
  }

-- | A policy that could never admit is a misconfiguration to refuse at install,
-- not at the moment a person is relying on it.
validatePolicy :: PolicyContext -> PolicyInput -> Either PolicyRefusal PolicyInput
validatePolicy context input = do
  unless (context.principalActive input.principal) (Left UnknownPrincipal)
  unless (creationAllowed context.objectives (RecordedAgent (Principal.VerifiedIdentity input.principal))) (Left PrincipalCannotCreateObjectives)
  forM_ input.repositories \repository -> unless (repository `elem` context.catalog) (Left (UnknownRepository repository))
  declaration <- maybe (Left (UnknownCoordinator input.coordinator)) Right (lookupDeclaration input.coordinator context.declarations)
  unless (agentEnabled declaration.enabled) (Left (UnknownCoordinator input.coordinator))
  case declaration.behavior of
    Flow {} -> Right ()
    CoordinatingSkill {} -> Right ()
    _ -> Left (CoordinatorNotCoordinating input.coordinator)
  case declaration.identity of
    Nothing -> Left CoordinatorHasNoIdentity
    Just IdentityDecl {principal} -> case mkAgentPrincipal (declarationCoordinateText principal) of
      Left _ -> Left CoordinatorHasNoIdentity
      Right _ -> Right ()
  unless (all (`Map.member` input.perObjective) [ActiveWork, ModelAttempts, Tokens, CostMicroUsd]) (Left EnvelopeDeniesModelAttempts)
  unless (Map.lookup CostMicroUsd input.perObjective == Just ExplicitlyUnbounded) (Left EnvelopeDeniesModelAttempts)
  forM_ (Map.toList input.perObjective) \(dimension, wanted) -> case (wanted, Map.lookup dimension input.total) of
    (_, Just ExplicitlyUnbounded) -> Right ()
    (Limited amount, Just (Limited available)) | amountUnits available >= amountUnits amount -> Right ()
    _ -> Left (TotalBelowPerObjective dimension)
  when (input.expiresAt <= context.now) (Left ExpiryInPast)
  when (input.expiresAt > addUTCTime (durationTime context.maximumLifetime) context.now) (Left ExpiryTooFar)
  pure input

lookupDeclaration :: AgentName -> [AgentDecl] -> Maybe AgentDecl
lookupDeclaration name declarations = case [declaration | declaration <- declarations, declaration.name == name] of
  declaration : _ -> Just declaration
  [] -> Nothing

-- | Never updates: a changed policy is a new policy and a revocation of the old
-- one, so every admission receipt stays pinned to the exact terms it ran under.
installPolicy :: (Store :> es, IOE :> es) => OperatorId -> PolicyContext -> PolicyInput -> Eff es (Either PolicyRefusal StandingPolicy)
installPolicy operator context input = case validatePolicy context input of
  Left refusal -> pure (Left refusal)
  Right checked -> do
    identifier <- liftIO newStandingPolicyId
    let facts =
          PolicyFacts
            { policyId = identifier,
              input = checked,
              digest = policyDigestFor checked,
              installedBy = operator,
              installedAt = context.now,
              revoked = Nothing,
              revision = initialRevision
            }
    runTransaction
      ( Tx.statement
          ( standingPolicyIdText identifier,
            principalText checked.principal,
            toJSON checked,
            policyDigestText facts.digest,
            operatorIdText operator,
            context.now,
            checked.expiresAt
          )
          insertPolicy
      )
    pure (Right (StandingPolicy facts))

revokePolicy :: (Store :> es) => OperatorId -> StandingPolicyId -> StateRevision "standing-policy" -> UTCTime -> Eff es (Either PolicyRefusal PolicyView)
revokePolicy operator identifier expected now = runTransaction do
  updated <- Tx.statement (standingPolicyIdText identifier, fromInteger (revisionNumber expected), operatorIdText operator, now) updateRevocation
  current <- readPolicy identifier
  pure case current of
    Left refusal -> Left refusal
    Right Nothing -> Left PolicyMissing
    Right (Just policy)
      | updated -> Right (policyView now policy)
      | otherwise -> Left PolicyConflict

readPolicy :: StandingPolicyId -> Transaction (Either PolicyRefusal (Maybe StandingPolicy))
readPolicy identifier = traverse decodePolicy <$> Tx.statement (standingPolicyIdText identifier) selectPolicy

-- | One keyset page, at most 100 rows.
listPolicies :: UTCTime -> Maybe AgentPrincipal -> Maybe StandingPolicyId -> Int -> Transaction (Either PolicyRefusal [PolicyView])
listPolicies now principal after limit = do
  rows <- Tx.statement (principalText <$> principal, standingPolicyIdText <$> after, fromIntegral (max 1 (min 100 limit))) selectPolicies
  pure (map (policyView now) <$> traverse decodePolicy rows)

-- | Lock-free, for the Flow's branch decision. 'reserveAdmission' is the authority.
coveringPolicies :: AgentPrincipal -> SourceKind -> UTCTime -> Transaction [StandingPolicy]
coveringPolicies principal source now = do
  rows <- Tx.statement (principalText principal, now) selectCovering
  pure
    [ policy
    | Right policy <- map decodePolicy rows,
      source `elem` (policyFacts policy).input.sources
    ]

-- | What a covered proposal is funded and staffed with. It crosses the journal,
-- so it holds the coordinator's name; the interpreter resolves its identity.
data Reservation = Reservation
  { policyId :: !StandingPolicyId,
    digest :: !PolicyDigest,
    envelope :: !Envelope,
    coordinator :: !AgentName
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AdmissionRefusal
  = NotCovered
  | PolicyGone !PolicyRefusal
  | AdmissionsExhausted !Int
  | TotalsExhausted !Dimension
  | AlreadyAdmitted !ProposalId
  deriving stock (Eq, Show)

-- | The bounded tag a metric or an operator reads.
admissionRefusalText :: AdmissionRefusal -> Text
admissionRefusalText = \case
  NotCovered -> "not-covered"
  PolicyGone _ -> "policy-gone"
  AdmissionsExhausted _ -> "admissions-exhausted"
  TotalsExhausted _ -> "totals-exhausted"
  AlreadyAdmitted _ -> "already-admitted"

-- | The fresh read: lock the row, re-check it against this instant, then take
-- one admission from the window and one whole per-objective envelope from the
-- totals. Totals are promises rather than measurements, and a reservation stays
-- consumed even when its admission later fails.
reserveAdmission :: ProposalId -> StandingPolicyId -> RequestedAuthority -> UTCTime -> Transaction (Either AdmissionRefusal Reservation)
reserveAdmission proposal identifier requested now = do
  row <- Tx.statement (standingPolicyIdText identifier) lockPolicy
  case traverse decodePolicy row of
    Left refusal -> pure (Left (PolicyGone refusal))
    Right Nothing -> pure (Left (PolicyGone PolicyMissing))
    Right (Just policy) -> do
      let facts = policyFacts policy
          input = facts.input
      existing <- Tx.statement (proposalIdText proposal) selectAdmissionExists
      inWindow <- fromIntegral <$> Tx.statement (standingPolicyIdText identifier, addUTCTime (negate (durationTime input.window)) now) countAdmissionsSince
      reservedSoFar <- Tx.statement (standingPolicyIdText identifier) countAdmissions
      case checks facts inWindow reservedSoFar existing of
        Left refusal -> pure (Left refusal)
        Right () -> do
          let envelope = Envelope {limits = input.perObjective, cutoff = addUTCTime (durationTime input.objectiveWindow) now}
              reservation = Reservation {policyId = identifier, digest = facts.digest, envelope, coordinator = input.coordinator}
          Tx.statement (proposalIdText proposal, standingPolicyIdText identifier, policyDigestText facts.digest, toJSON reservation, now) insertAdmission
          pure (Right reservation)
  where
    checks facts inWindow reservedSoFar existing = do
      let input = facts.input
      when (isJust facts.revoked) (Left (PolicyGone PolicyRevoked))
      when (now >= input.expiresAt) (Left (PolicyGone PolicyExpired))
      when existing (Left (AlreadyAdmitted proposal))
      unless (requested.repository `elem` input.repositories && requested.actionClass `elem` input.actionClasses) (Left NotCovered)
      when (inWindow >= initiativeLimitInt input.admissionsPerWindow) (Left (AdmissionsExhausted inWindow))
      forM_ (firstExhausted input reservedSoFar) (Left . TotalsExhausted)

-- | The first dimension whose total cannot cover one more whole envelope. Active
-- work is a gauge each root bounds for itself, not something admissions spend.
firstExhausted :: PolicyInput -> Int64 -> Maybe Dimension
firstExhausted input reservedSoFar =
  case [ dimension
       | (dimension, amount, available) <- spendable input,
         (toInteger reservedSoFar + 1) * amountUnits amount > amountUnits available
       ] of
    dimension : _ -> Just dimension
    [] -> Nothing

spendable :: PolicyInput -> [(Dimension, ResourceAmount, ResourceAmount)]
spendable input =
  [ (dimension, amount, available)
  | (dimension, Limited amount) <- Map.toList input.perObjective,
    dimension /= ActiveWork,
    Just (Limited available) <- [Map.lookup dimension input.total]
  ]

-- | A retried step finds the reservation it already took.
readReservation :: ProposalId -> Transaction (Maybe Reservation)
readReservation proposal = do
  stored <- Tx.statement (proposalIdText proposal) selectReservation
  pure case Aeson.fromJSON <$> stored of
    Just (Aeson.Success reservation) -> Just reservation
    _ -> Nothing

data AdmissionStage
  = Created !ObjectiveId
  | Funded !ExecutionRootId
  | Staffed
  | Launched !WorkflowId
  | AdmissionFailed !RefusalKind !Text
  deriving stock (Eq, Show)

recordAdmissionStage :: ProposalId -> AdmissionStage -> UTCTime -> Transaction ()
recordAdmissionStage proposal stage now = case stage of
  Created objective -> update "created" (Just (objectiveIdText objective)) Nothing Nothing Nothing
  Funded root -> update "funded" Nothing (Just (executionRootIdText root)) Nothing Nothing
  Staffed -> update "staffed" Nothing Nothing Nothing Nothing
  Launched (WorkflowId workflow) -> update "launched" Nothing Nothing (Just workflow) Nothing
  AdmissionFailed kind detail -> update "refused" Nothing Nothing Nothing (Just (refusalKindText kind <> ": " <> Text.take 256 detail))
  where
    update name objective root workflow refusal =
      Tx.statement (proposalIdText proposal, name, objective, root, workflow, refusal, now) updateAdmissionStage

data AdmissionView = AdmissionView
  { proposalId :: !Text,
    policyId :: !Text,
    digest :: !Text,
    stage :: !Text,
    objectiveId :: !(Maybe Text),
    rootId :: !(Maybe Text),
    coordinatorWorkflowId :: !(Maybe Text),
    refusal :: !(Maybe Text),
    reservedAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

readAdmission :: ProposalId -> Transaction (Maybe AdmissionView)
readAdmission proposal = Tx.statement (proposalIdText proposal) selectAdmission

-- | One keyset page of admissions, newest proposal last, at most 100 rows.
listAdmissions :: Maybe StandingPolicyId -> Maybe ProposalId -> Int -> Transaction [AdmissionView]
listAdmissions policy after limit =
  Tx.statement (standingPolicyIdText <$> policy, proposalIdText <$> after, fromIntegral (max 1 (min 100 limit))) selectAdmissions

-- | Unrevoked, unexpired policies, bounded, for inspection.
livePolicies :: UTCTime -> Transaction (Either PolicyRefusal [StandingPolicy])
livePolicies now = traverse decodePolicy <$> Tx.statement now selectLive

-- | Remaining capacity at an instant, arithmetic over the policy's own rows.
data PolicyUsage = PolicyUsage
  { policy :: !PolicyView,
    admissionsInWindow :: !Int,
    admissionsPerWindow :: !Int,
    reserved :: !Int,
    remaining :: !Value,
    exhausted :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

policyUsage :: UTCTime -> StandingPolicy -> Transaction PolicyUsage
policyUsage now policy = do
  let facts = policyFacts policy
      input = facts.input
      identifier = standingPolicyIdText facts.policyId
  inWindow <- fromIntegral <$> Tx.statement (identifier, addUTCTime (negate (durationTime input.window)) now) countAdmissionsSince
  reservedSoFar <- Tx.statement identifier countAdmissions
  pure
    PolicyUsage
      { policy = policyView now policy,
        admissionsInWindow = inWindow,
        admissionsPerWindow = initiativeLimitInt input.admissionsPerWindow,
        reserved = fromIntegral reservedSoFar,
        remaining =
          object
            [ toKey dimension .= (amountUnits available - toInteger reservedSoFar * amountUnits amount)
            | (dimension, amount, available) <- spendable input
            ],
        exhausted =
          ["admissions" | inWindow >= initiativeLimitInt input.admissionsPerWindow]
            <> [Text.pack (show dimension) | Just dimension <- [firstExhausted input reservedSoFar]]
      }
  where
    toKey = Key.fromString . show

decodePolicy :: PolicyRow -> Either PolicyRefusal StandingPolicy
decodePolicy row = do
  policyId <- unreadable (parseStandingPolicyId row.policyId)
  input <- case Aeson.fromJSON row.document of
    Aeson.Success value -> Right value
    Aeson.Error _ -> Left PolicyUnreadable
  installedBy <- unreadable (parseOperatorId row.installedBy)
  revokedBy <- traverse (unreadable . parseOperatorId) row.revokedBy
  revision <- unreadable (parseRevision (toInteger row.revision))
  pure
    ( StandingPolicy
        PolicyFacts
          { policyId,
            input,
            digest = PolicyDigest row.digest,
            installedBy,
            installedAt = row.installedAt,
            revoked = Revocation <$> revokedBy <*> row.revokedAt,
            revision
          }
    )
  where
    unreadable :: Either Text value -> Either PolicyRefusal value
    unreadable = either (const (Left PolicyUnreadable)) Right

data PolicyRow = PolicyRow
  { policyId :: !Text,
    document :: !Value,
    digest :: !Text,
    installedBy :: !Text,
    installedAt :: !UTCTime,
    revokedBy :: !(Maybe Text),
    revokedAt :: !(Maybe UTCTime),
    revision :: !Int64
  }

policyRow :: D.Row PolicyRow
policyRow =
  PolicyRow
    <$> text
    <*> D.column (D.nonNullable D.jsonb)
    <*> text
    <*> text
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.int8)
  where
    text = D.column (D.nonNullable D.text)

policyColumns :: Text
policyColumns = "policy_id,policy,digest,installed_by,installed_at,revoked_by,revoked_at,revision::bigint"

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

nullableText :: E.Params (Maybe Text)
nullableText = E.param (E.nullable E.text)

instantParam :: E.Params UTCTime
instantParam = E.param (E.nonNullable E.timestamptz)

insertPolicy :: Statement (Text, Text, Value, Text, Text, UTCTime, UTCTime) ()
insertPolicy =
  preparable
    "INSERT INTO shikigami.initiative_standing_policies (policy_id,principal,policy,digest,installed_by,installed_at,expires_at,revision) VALUES ($1,$2,$3,$4,$5,$6,$7,0)"
    (contrazip7 textParam textParam (E.param (E.nonNullable E.jsonb)) textParam textParam instantParam instantParam)
    D.noResult

updateRevocation :: Statement (Text, Int64, Text, UTCTime) Bool
updateRevocation =
  preparable
    "UPDATE shikigami.initiative_standing_policies SET revoked_by=$3, revoked_at=$4, revision=revision+1 WHERE policy_id=$1 AND revision=$2::bigint AND revoked_at IS NULL"
    (contrazip4 textParam (E.param (E.nonNullable E.int8)) textParam instantParam)
    ((> 0) <$> D.rowsAffected)

selectPolicy :: Statement Text (Maybe PolicyRow)
selectPolicy = preparable ("SELECT " <> policyColumns <> " FROM shikigami.initiative_standing_policies WHERE policy_id=$1") textParam (D.rowMaybe policyRow)

lockPolicy :: Statement Text (Maybe PolicyRow)
lockPolicy = preparable ("SELECT " <> policyColumns <> " FROM shikigami.initiative_standing_policies WHERE policy_id=$1 FOR UPDATE") textParam (D.rowMaybe policyRow)

selectPolicies :: Statement (Maybe Text, Maybe Text, Int64) [PolicyRow]
selectPolicies =
  preparable
    ("SELECT " <> policyColumns <> " FROM shikigami.initiative_standing_policies WHERE ($1::text IS NULL OR principal=$1) AND ($2::text IS NULL OR policy_id > $2) ORDER BY policy_id LIMIT $3")
    (contrazip3 nullableText nullableText (E.param (E.nonNullable E.int8)))
    (D.rowList policyRow)

selectCovering :: Statement (Text, UTCTime) [PolicyRow]
selectCovering =
  preparable
    ("SELECT " <> policyColumns <> " FROM shikigami.initiative_standing_policies WHERE principal=$1 AND revoked_at IS NULL AND expires_at > $2 ORDER BY installed_at,policy_id LIMIT 64")
    (contrazip2 textParam instantParam)
    (D.rowList policyRow)

selectAdmissionExists :: Statement Text Bool
selectAdmissionExists =
  preparable
    "SELECT EXISTS (SELECT 1 FROM shikigami.initiative_admissions WHERE proposal_id=$1)"
    textParam
    (D.singleRow (D.column (D.nonNullable D.bool)))

countAdmissionsSince :: Statement (Text, UTCTime) Int64
countAdmissionsSince =
  preparable
    "SELECT count(*) FROM shikigami.initiative_admissions WHERE policy_id=$1 AND reserved_at > $2"
    (contrazip2 textParam instantParam)
    (D.singleRow (D.column (D.nonNullable D.int8)))

countAdmissions :: Statement Text Int64
countAdmissions =
  preparable
    "SELECT count(*) FROM shikigami.initiative_admissions WHERE policy_id=$1"
    textParam
    (D.singleRow (D.column (D.nonNullable D.int8)))

insertAdmission :: Statement (Text, Text, Text, Value, UTCTime) ()
insertAdmission =
  preparable
    "INSERT INTO shikigami.initiative_admissions (proposal_id,policy_id,policy_digest,reserved,stage,reserved_at,updated_at) VALUES ($1,$2,$3,$4,'reserved',$5,$5)"
    (contrazip5 textParam textParam textParam (E.param (E.nonNullable E.jsonb)) instantParam)
    D.noResult

selectReservation :: Statement Text (Maybe Value)
selectReservation =
  preparable
    "SELECT reserved FROM shikigami.initiative_admissions WHERE proposal_id=$1"
    textParam
    (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

updateAdmissionStage :: Statement (Text, Text, Maybe Text, Maybe Text, Maybe Text, Maybe Text, UTCTime) ()
updateAdmissionStage =
  preparable
    "UPDATE shikigami.initiative_admissions SET stage=$2, objective_id=COALESCE($3,objective_id), root_id=COALESCE($4,root_id), coordinator_workflow_id=COALESCE($5,coordinator_workflow_id), refusal=COALESCE($6,refusal), updated_at=$7 WHERE proposal_id=$1"
    (contrazip7 textParam textParam nullableText nullableText nullableText nullableText instantParam)
    D.noResult

selectAdmission :: Statement Text (Maybe AdmissionView)
selectAdmission =
  preparable
    "SELECT proposal_id,policy_id,policy_digest,stage,objective_id,root_id,coordinator_workflow_id,refusal,reserved_at,updated_at FROM shikigami.initiative_admissions WHERE proposal_id=$1"
    textParam
    (D.rowMaybe admissionRow)

selectAdmissions :: Statement (Maybe Text, Maybe Text, Int64) [AdmissionView]
selectAdmissions =
  preparable
    "SELECT proposal_id,policy_id,policy_digest,stage,objective_id,root_id,coordinator_workflow_id,refusal,reserved_at,updated_at FROM shikigami.initiative_admissions WHERE ($1::text IS NULL OR policy_id=$1) AND ($2::text IS NULL OR proposal_id > $2) ORDER BY proposal_id LIMIT $3"
    (contrazip3 nullableText nullableText (E.param (E.nonNullable E.int8)))
    (D.rowList admissionRow)

selectLive :: Statement UTCTime [PolicyRow]
selectLive =
  preparable
    ("SELECT " <> policyColumns <> " FROM shikigami.initiative_standing_policies WHERE revoked_at IS NULL AND expires_at > $1 ORDER BY policy_id LIMIT 256")
    instantParam
    (D.rowList policyRow)

admissionRow :: D.Row AdmissionView
admissionRow =
  AdmissionView
    <$> text
    <*> text
    <*> text
    <*> text
    <*> maybeText
    <*> maybeText
    <*> maybeText
    <*> maybeText
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
  where
    text = D.column (D.nonNullable D.text)
    maybeText = D.column (D.nullable D.text)
