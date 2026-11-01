{-# LANGUAGE TypeFamilies #-}

-- | Replay-safe persistence and adjudication for architecture-practice reviews.
--
-- The public effect is deliberately narrower than the generic Flow memory
-- capability. A review transition owns logical ids, typed envelopes, an exact
-- practice scope, and Kioku's separate record/retire protocol. Flow code gets
-- these operations and no Kioku environment or IO capability.
--
-- The specialist Flow installs this interpreter with static journal
-- labels declared in domain/shikigami/agent-run.keiro. Every durable call
-- journals its operation; the explicit unjournaled interpreter is test-only.
module Shikigami.PracticeReview.Memory
  ( PracticeReviewMemory,
    PracticeReviewMemoryEnv (..),
    PracticeReviewMemoryEnvelope (..),
    ReviewRecallContext (..),
    AdjudicatedPracticeReview (..),
    RecalledPracticeReviews (..),
    ReviewMemoryDiagnostic (..),
    PracticeReviewChainEntry (..),
    PracticeReviewChain (..),
    ReviewMemoryError (..),
    provisionalMemoryId,
    resolvedMemoryId,
    practiceReviewScope,
    practiceReviewTags,
    encodePracticeReviewMemory,
    decodePracticeReviewMemory,
    appliesTo,
    ReviewIdentityRef,
    allocatedReviewId,
    reserveReviewIdentity,
    ResolvedPracticeReview (..),
    rememberProvisional,
    resolveReview,
    recallPracticeReviews,
    recallPracticeReviewChain,
    runPracticeReviewMemory,
    runPracticeReviewMemoryUnjournaled,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value (String),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.KindID.V7 qualified as KindID
import Data.List (sortOn)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (StepName (..), Workflow, step)
import Kioku.Api.Scope (MemoryScope (..), ScopeKind (..))
import Kioku.Api.Types qualified as Kioku
import Kioku.Id (MemoryId, SessionId, idText, parseId)
import Kioku.Memory (MemoryWriteError (..))
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..), SupersedeMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (ResolvedAgentIdentity)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (shikigamiNamespace)
import Shikigami.PracticeReview
  ( Applicability (..),
    ContentReference (..),
    DependencyName,
    EvidenceItem (..),
    PracticeKey,
    PracticeReviewResolution (..),
    PracticeReviewResolutionRequest (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ResolutionId,
    ResolutionOutcome (..),
    ReviewId,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    ValidatedResolutionRequest,
    confidencePercent,
    dependencyNameText,
    practiceKeyText,
    resolutionIdText,
    reviewIdText,
    validateResolution,
    validateVerdict,
    validatedResolutionRequestValue,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.IdentityStore (ReviewIdentityRef, allocatedReviewId)
import Shikigami.PracticeReview.IdentityStore qualified as IdentityStore
import Shikigami.Prelude (Generic, eventAesonOptions, genericParseJSON, genericToJSON)
import Shikigami.Repository (RelativePath, RepositoryId, relativePathText, repositoryId, repositoryIdText)

-- | Versioned content stored in Kioku's text payload.
--
-- A resolved memory repeats the verdict intentionally. A resolution alone has
-- the human outcome and applicability, but not the evidence and claims a later
-- review needs to reuse or avoid repeating.
data PracticeReviewMemoryEnvelope
  = ProvisionalReview !ValidatedPracticeReviewVerdict
  | ResolvedReview !ValidatedPracticeReviewVerdict !ValidatedPracticeReviewResolution
  deriving stock (Eq, Show)

-- | The exact bounded context against which applicability is evaluated.
data ReviewRecallContext = ReviewRecallContext
  { project :: !ProjectRef,
    path :: !(Maybe RelativePath),
    dependencies :: !(Set DependencyName),
    practice :: !PracticeKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A human resolution paired with the evidence-bearing verdict it adjudicated.
data AdjudicatedPracticeReview = AdjudicatedPracticeReview
  { verdict :: !ValidatedPracticeReviewVerdict,
    resolution :: !ValidatedPracticeReviewResolution
  }
  deriving stock (Eq, Show)

-- | The active review view, divided so a rejection can never become a rule.
data RecalledPracticeReviews = RecalledPracticeReviews
  { guiding :: ![AdjudicatedPracticeReview],
    doNotRepeat :: ![AdjudicatedPracticeReview],
    pending :: ![ValidatedPracticeReviewVerdict],
    retired :: ![AdjudicatedPracticeReview],
    diagnostics :: ![ReviewMemoryDiagnostic]
  }
  deriving stock (Eq, Show)

-- | A stable, non-fatal reason a row was excluded from the active view.
data ReviewMemoryDiagnostic = ReviewMemoryDiagnostic
  { memoryId :: !Text,
    code :: !Text,
    detail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One immutable row in Kioku's full supersession chain.
data PracticeReviewChainEntry = PracticeReviewChainEntry
  { memoryId :: !Text,
    status :: !Text,
    supersededBy :: !(Maybe Text),
    supersedes :: !(Maybe Text),
    envelope :: !(Maybe PracticeReviewMemoryEnvelope),
    diagnostic :: !(Maybe ReviewMemoryDiagnostic)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Audit history rooted at a review's deterministic provisional id.
data PracticeReviewChain = PracticeReviewChain
  { entries :: ![PracticeReviewChainEntry],
    diagnostics :: ![ReviewMemoryDiagnostic]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Domain failures returned through the journaled capability result.
--
-- Store failures remain exceptions: they mean the operation could not be
-- attempted, not that the requested state transition was rejected.
data ReviewMemoryError
  = ReviewMemoryNotFound !Text
  | ReviewMemoryMalformed !Text !Text
  | ReviewExpectedProvisional !Text
  | ReviewProvisionalIdMismatch !MemoryId !MemoryId
  | ReviewIdMismatch !ReviewId !ReviewId
  | ReviewContentConflict !MemoryId !Text
  | ResolutionConflict !MemoryId
  | ReviewMemoryRefused !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewMemoryError where
  toJSON = genericToJSON eventAesonOptions

instance FromJSON ReviewMemoryError where
  parseJSON = genericParseJSON eventAesonOptions

instance ToJSON PracticeReviewMemoryEnvelope where
  toJSON = \case
    ProvisionalReview verdict ->
      object
        [ "schemaVersion" .= reviewMemorySchemaVersion,
          "kind" .= ("provisional" :: Text),
          "verdict" .= validatedVerdictValue verdict
        ]
    ResolvedReview verdict resolution ->
      object
        [ "schemaVersion" .= reviewMemorySchemaVersion,
          "kind" .= ("resolved" :: Text),
          "verdict" .= validatedVerdictValue verdict,
          "resolution" .= validatedResolutionValue resolution
        ]

instance FromJSON PracticeReviewMemoryEnvelope where
  parseJSON = withObject "PracticeReviewMemoryEnvelope" \objectValue -> do
    schemaVersion <- objectValue .: "schemaVersion"
    if schemaVersion /= reviewMemorySchemaVersion
      then fail ("unsupported practice-review memory schema version: " <> show (schemaVersion :: Int))
      else do
        kind <- objectValue .: "kind"
        case (kind :: Text) of
          "provisional" -> ProvisionalReview <$> (objectValue .: "verdict" >>= parseValidatedVerdict)
          "resolved" -> do
            verdict <- objectValue .: "verdict" >>= parseValidatedVerdict
            resolution <- objectValue .: "resolution" >>= parseValidatedResolution
            ensureMatchingReviewIds verdict resolution
            pure (ResolvedReview verdict resolution)
          other -> fail ("unsupported practice-review memory kind: " <> Text.unpack other)

instance ToJSON AdjudicatedPracticeReview where
  toJSON AdjudicatedPracticeReview {verdict, resolution} =
    object
      [ "verdict" .= validatedVerdictValue verdict,
        "resolution" .= validatedResolutionValue resolution
      ]

instance FromJSON AdjudicatedPracticeReview where
  parseJSON = withObject "AdjudicatedPracticeReview" \objectValue -> do
    verdict <- objectValue .: "verdict" >>= parseValidatedVerdict
    resolution <- objectValue .: "resolution" >>= parseValidatedResolution
    ensureMatchingReviewIds verdict resolution
    pure AdjudicatedPracticeReview {verdict, resolution}

instance ToJSON RecalledPracticeReviews where
  toJSON RecalledPracticeReviews {guiding, doNotRepeat, pending, retired, diagnostics} =
    object
      [ "guiding" .= guiding,
        "doNotRepeat" .= doNotRepeat,
        "pending" .= (validatedVerdictValue <$> pending),
        "retired" .= retired,
        "diagnostics" .= diagnostics
      ]

instance FromJSON RecalledPracticeReviews where
  parseJSON = withObject "RecalledPracticeReviews" \objectValue -> do
    guiding <- objectValue .: "guiding"
    doNotRepeat <- objectValue .: "doNotRepeat"
    rawPending <- objectValue .: "pending"
    pending <- traverse parseValidatedVerdict rawPending
    retired <- objectValue .: "retired"
    diagnostics <- objectValue .: "diagnostics"
    pure RecalledPracticeReviews {guiding, doNotRepeat, pending, retired, diagnostics}

reviewMemorySchemaVersion :: Int
reviewMemorySchemaVersion = 1

parseValidatedVerdict :: PracticeReviewVerdict -> Parser ValidatedPracticeReviewVerdict
parseValidatedVerdict raw =
  either (fail . renderContractErrors) pure (validateVerdict raw)

parseValidatedResolution :: PracticeReviewResolution -> Parser ValidatedPracticeReviewResolution
parseValidatedResolution raw =
  either (fail . renderContractErrors) pure (validateResolution raw)

renderContractErrors :: (Show error) => error -> String
renderContractErrors = show

ensureMatchingReviewIds :: ValidatedPracticeReviewVerdict -> ValidatedPracticeReviewResolution -> Parser ()
ensureMatchingReviewIds validatedVerdict validatedResolution =
  let PracticeReviewVerdict {reviewId = verdictReviewId} = validatedVerdictValue validatedVerdict
      PracticeReviewResolution {reviewId = resolutionReviewId} = validatedResolutionValue validatedResolution
   in if verdictReviewId == resolutionReviewId
        then pure ()
        else fail "resolved practice-review memory carries different verdict and resolution review ids"

-- | Compact deterministic JSON text used as Kioku content.
encodePracticeReviewMemory :: PracticeReviewMemoryEnvelope -> Text
encodePracticeReviewMemory = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

-- | Decode and revalidate one Kioku content payload.
decodePracticeReviewMemory :: Text -> Either Text PracticeReviewMemoryEnvelope
decodePracticeReviewMemory content =
  firstText (eitherDecodeStrict' (TextEncoding.encodeUtf8 content))
  where
    firstText = either (Left . Text.pack) Right

-- | Stable id of a provisional finding across workflow identities and replays.
provisionalMemoryId :: ReviewId -> MemoryId
provisionalMemoryId reviewId = reviewMemoryId ["provisional", reviewIdText reviewId]

-- | Stable id of an adjudication command across workflow identities and replays.
resolvedMemoryId :: ResolutionId -> MemoryId
resolvedMemoryId resolutionId = reviewMemoryId ["resolved", resolutionIdText resolutionId]

reviewMemoryId :: [Text] -> MemoryId
reviewMemoryId identityParts =
  KindID.decorateKindID $
    UUID.V5.generateNamed reviewMemoryNamespace $
      ByteString.unpack (TextEncoding.encodeUtf8 (lengthPrefixed identityParts))

reviewMemoryNamespace :: UUID.UUID
reviewMemoryNamespace =
  UUID.V5.generateNamed
    UUID.V5.namespaceURL
    (ByteString.unpack (TextEncoding.encodeUtf8 "mori://shinzui/shikigami/contracts/practice-review-memory/v1"))

lengthPrefixed :: [Text] -> Text
lengthPrefixed = Text.intercalate "|" . fmap (\part -> Text.pack (show (Text.length part)) <> ":" <> part)

-- | Shared cross-agent scope for one normalized practice.
practiceReviewScope :: PracticeKey -> MemoryScope
practiceReviewScope practice =
  ScopeEntity shikigamiNamespace (ScopeKind "practice-review") (normalizeToken (practiceKeyText practice))

-- | Stable indexed metadata duplicated from the authoritative envelope.
practiceReviewTags :: PracticeReviewMemoryEnvelope -> Set Text
practiceReviewTags envelope =
  Set.fromList
    ( [ "practice-review",
        "practice-review:v1",
        "state:" <> stateTag,
        "practice:" <> practiceKeyText practiceKey,
        "review:" <> reviewIdText reviewId,
        "classification:" <> enumText classification
      ]
        <> maybe [] (\value -> ["resolution:" <> value]) resolutionValue
        <> maybe [] (\value -> ["outcome:" <> value]) outcomeValue
        <> (("project:" <>) . normalizeToken <$> projectValues)
        <> (("path:" <>) . normalizeToken . relativePathText <$> tagPaths)
        <> (("dependency:" <>) . normalizeToken . dependencyNameText <$> tagDependencies)
    )
  where
    (validatedVerdict, stateTag, resolutionValue, outcomeValue, applicabilityForTags) =
      case envelope of
        ProvisionalReview verdict ->
          (verdict, "provisional", Nothing, Nothing, verdictApplicability verdict)
        ResolvedReview verdict resolution ->
          let PracticeReviewResolution {resolutionId, outcome, resultingApplicability} = validatedResolutionValue resolution
           in ( verdict,
                "resolved",
                Just (resolutionIdText resolutionId),
                Just (enumText outcome),
                maybe (verdictApplicability verdict) id resultingApplicability
              )
    rawVerdict@PracticeReviewVerdict {reviewId, practice = practiceKey, classification} =
      validatedVerdictValue validatedVerdict
    Applicability {paths = tagPaths, dependencies = tagDependencies} = applicabilityForTags
    projectValues = repositoryValues rawVerdict applicabilityForTags

repositoryValues :: PracticeReviewVerdict -> Applicability -> [Text]
repositoryValues PracticeReviewVerdict {targetEvidence, applicability = verdictScope} Applicability {projects = selectedProjects} =
  Set.toAscList $
    Set.fromList
      [ repositoryIdText repository
      | ProjectRef {repository} <- selectedProjects <> verdictProjects <> evidenceProjects targetEvidence
      ]
  where
    Applicability {projects = verdictProjects} = verdictScope

evidenceProjects :: [EvidenceItem] -> [ProjectRef]
evidenceProjects = fmap \EvidenceItem {content = ContentReference {project}} -> project

verdictApplicability :: ValidatedPracticeReviewVerdict -> Applicability
verdictApplicability validated =
  let PracticeReviewVerdict {applicability} = validatedVerdictValue validated
   in applicability

enumText :: (ToJSON value) => value -> Text
enumText value =
  case toJSON value of
    String rendered -> rendered
    other -> error ("Shikigami.PracticeReview.Memory: expected enum JSON string, got " <> show other)

normalizeToken :: Text -> Text
normalizeToken = Text.toCaseFold . Text.strip

-- | Every non-empty applicability dimension must match the current context.
appliesTo :: Applicability -> ReviewRecallContext -> Bool
appliesTo Applicability {projects, paths, dependencies, practices} ReviewRecallContext {project, path, dependencies = currentDependencies, practice} =
  matchesProjects projects project
    && matchesPaths paths path
    && matchesDependencies dependencies currentDependencies
    && matchesPractices practices practice

matchesProjects :: [ProjectRef] -> ProjectRef -> Bool
matchesProjects [] _ = True
matchesProjects allowed ProjectRef {repository = wanted} =
  any (\ProjectRef {repository} -> repository == wanted) allowed

matchesPaths :: [RelativePath] -> Maybe RelativePath -> Bool
matchesPaths [] _ = True
matchesPaths _ Nothing = False
matchesPaths allowed (Just wanted) = any (`pathContains` wanted) allowed

pathContains :: RelativePath -> RelativePath -> Bool
pathContains parent child =
  let parentText = relativePathText parent
      childText = relativePathText child
   in childText == parentText || (parentText <> "/") `Text.isPrefixOf` childText

matchesDependencies :: [DependencyName] -> Set DependencyName -> Bool
matchesDependencies [] _ = True
matchesDependencies allowed current =
  not (Set.disjoint (Set.fromList (normalizeToken . dependencyNameText <$> allowed)) (Set.map (normalizeToken . dependencyNameText) current))

matchesPractices :: [PracticeKey] -> PracticeKey -> Bool
matchesPractices [] _ = True
matchesPractices allowed wanted =
  any (\candidate -> normalizeToken (practiceKeyText candidate) == normalizeToken (practiceKeyText wanted)) allowed

-- | Capability environment installed by the agent-run workflow.
data PracticeReviewMemoryEnv = PracticeReviewMemoryEnv
  { appEnv :: !AppEnv,
    agent :: !AgentDecl,
    identity :: !ResolvedAgentIdentity,
    sessionId :: !(Maybe SessionId)
  }

data PracticeReviewMemory :: Effect where
  ReserveReviewIdentity :: ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> PracticeReviewMemory m (Either ReviewMemoryError ReviewIdentityRef)
  RememberProvisional :: ReviewIdentityRef -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> PracticeReviewMemory m (Either ReviewMemoryError MemoryId)
  ResolveReview :: MemoryId -> ValidatedResolutionRequest -> PracticeReviewMemory m (Either ReviewMemoryError ResolvedPracticeReview)
  RecallPracticeReviews :: ReviewRecallContext -> PracticeReviewMemory m RecalledPracticeReviews
  RecallPracticeReviewChain :: ReviewId -> PracticeReviewMemory m PracticeReviewChain

type instance DispatchOf PracticeReviewMemory = Dynamic

data ResolvedPracticeReview = ResolvedPracticeReview
  { memoryId :: !MemoryId,
    resolution :: !ValidatedPracticeReviewResolution
  }
  deriving stock (Eq, Show)

instance ToJSON ResolvedPracticeReview where
  toJSON ResolvedPracticeReview {memoryId, resolution} = object ["memoryId" .= memoryId, "resolution" .= validatedResolutionValue resolution]

instance FromJSON ResolvedPracticeReview where
  parseJSON = withObject "ResolvedPracticeReview" \value ->
    ResolvedPracticeReview <$> value .: "memoryId" <*> (value .: "resolution" >>= parseValidatedResolution)

reserveReviewIdentity :: (PracticeReviewMemory :> es) => ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> Eff es (Either ReviewMemoryError ReviewIdentityRef)
reserveReviewIdentity trigger practice specialist = send (ReserveReviewIdentity trigger practice specialist)

rememberProvisional :: (PracticeReviewMemory :> es) => ReviewIdentityRef -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> Eff es (Either ReviewMemoryError MemoryId)
rememberProvisional reference prior verdict = send (RememberProvisional reference prior verdict)

resolveReview :: (PracticeReviewMemory :> es) => MemoryId -> ValidatedResolutionRequest -> Eff es (Either ReviewMemoryError ResolvedPracticeReview)
resolveReview provisional resolution = send (ResolveReview provisional resolution)

recallPracticeReviews :: (PracticeReviewMemory :> es) => ReviewRecallContext -> Eff es RecalledPracticeReviews
recallPracticeReviews context = send (RecallPracticeReviews context)

recallPracticeReviewChain :: (PracticeReviewMemory :> es) => ReviewId -> Eff es PracticeReviewChain
recallPracticeReviewChain review = send (RecallPracticeReviewChain review)

-- | Interpret review persistence through fixed, declarable Keiro steps.
runPracticeReviewMemory :: (Workflow :> es, IOE :> es) => PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemory = runPracticeReviewMemoryWithJournal True

-- | Test interpreter for exercising several operations without fixed journal
-- labels. Durable runtime code always uses 'runPracticeReviewMemory'.
runPracticeReviewMemoryUnjournaled :: (Workflow :> es, IOE :> es) => PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemoryUnjournaled = runPracticeReviewMemoryWithJournal False

runPracticeReviewMemoryWithJournal :: (Workflow :> es, IOE :> es) => Bool -> PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemoryWithJournal journalReviewMemory env action =
  interpret
    ( \_ -> \case
        ReserveReviewIdentity trigger practice specialist ->
          runOperation journalReviewMemory "practice-review-reserve-identity" (fmap (either (Left . ReviewMemoryRefused) Right) (IdentityStore.reserveReviewIdentity env.appEnv env.identity trigger practice specialist))
        RememberProvisional reference prior verdict ->
          runOperation journalReviewMemory "practice-review-remember-provisional" (rememberProvisionalIO env reference prior verdict)
        ResolveReview provisional resolution ->
          runOperation journalReviewMemory "practice-review-resolve" (resolveReviewIO env provisional resolution)
        RecallPracticeReviews context ->
          runOperation journalReviewMemory "practice-review-recall" (recallPracticeReviewsIO env context)
        RecallPracticeReviewChain review ->
          runOperation journalReviewMemory "practice-review-chain" (recallPracticeReviewChainIO env review)
    )
    action
  where
    runOperation journal label operation
      | journal = step (StepName label) (liftIO operation)
      | otherwise = liftIO operation

rememberProvisionalIO :: PracticeReviewMemoryEnv -> ReviewIdentityRef -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> IO (Either ReviewMemoryError MemoryId)
rememberProvisionalIO env reference prior validatedVerdict =
  IdentityStore.verifyReviewIdentity env.appEnv env.identity reference validatedVerdict >>= \case
    Left problem -> pure (Left (ReviewMemoryRefused problem))
    Right () -> rememberAllocatedProvisionalIO env prior validatedVerdict

rememberAllocatedProvisionalIO :: PracticeReviewMemoryEnv -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> IO (Either ReviewMemoryError MemoryId)
rememberAllocatedProvisionalIO env prior validatedVerdict = do
  let PracticeReviewVerdict {reviewId, practice} = validatedVerdictValue validatedVerdict
      candidate = provisionalMemoryId reviewId
      envelope = ProvisionalReview validatedVerdict
  recordCandidate env candidate practice (verdictConfidence validatedVerdict) Kioku.MemoryPattern prior envelope >>= \case
    Left err -> pure (Left err)
    Right _ -> finishTransition env prior candidate

resolveReviewIO :: PracticeReviewMemoryEnv -> MemoryId -> ValidatedResolutionRequest -> IO (Either ReviewMemoryError ResolvedPracticeReview)
resolveReviewIO env suppliedProvisional request = do
  let PracticeReviewResolutionRequest {reviewId} = validatedResolutionRequestValue request
  if suppliedProvisional /= provisionalMemoryId reviewId
    then pure (Left (ReviewProvisionalIdMismatch (provisionalMemoryId reviewId) suppliedProvisional))
    else
      loadEnvelope env suppliedProvisional >>= \case
        Left problem -> pure (Left problem)
        Right (ResolvedReview _ _) -> pure (Left (ReviewExpectedProvisional (idText suppliedProvisional)))
        Right (ProvisionalReview _) ->
          IdentityStore.reserveResolutionIdentity env.appEnv env.identity request >>= \case
            Left problem -> pure (Left (ReviewMemoryRefused problem))
            Right resolution -> fmap (fmap (\memoryId -> ResolvedPracticeReview {memoryId, resolution})) (resolveAllocatedReviewIO env suppliedProvisional resolution)

resolveAllocatedReviewIO :: PracticeReviewMemoryEnv -> MemoryId -> ValidatedPracticeReviewResolution -> IO (Either ReviewMemoryError MemoryId)
resolveAllocatedReviewIO env suppliedProvisional validatedResolution = do
  let PracticeReviewResolution {reviewId = resolutionReviewId, resolutionId, outcome} = validatedResolutionValue validatedResolution
      expectedProvisional = provisionalMemoryId resolutionReviewId
  if suppliedProvisional /= expectedProvisional
    then pure (Left (ReviewProvisionalIdMismatch expectedProvisional suppliedProvisional))
    else
      loadEnvelope env suppliedProvisional >>= \case
        Left err -> pure (Left err)
        Right (ResolvedReview _ _) -> pure (Left (ReviewExpectedProvisional (idText suppliedProvisional)))
        Right (ProvisionalReview verdict) -> do
          let PracticeReviewVerdict {reviewId = verdictReviewId, practice} = validatedVerdictValue verdict
          if verdictReviewId /= resolutionReviewId
            then pure (Left (ReviewIdMismatch verdictReviewId resolutionReviewId))
            else do
              let candidate = resolvedMemoryId resolutionId
                  envelope = ResolvedReview verdict validatedResolution
                  memoryType = resolutionMemoryType outcome
              recordCandidate env candidate practice Kioku.HighConfidence memoryType (Just suppliedProvisional) envelope >>= \case
                Left err -> pure (Left err)
                Right _ -> finishTransition env (Just suppliedProvisional) candidate

finishTransition :: PracticeReviewMemoryEnv -> Maybe MemoryId -> MemoryId -> IO (Either ReviewMemoryError MemoryId)
finishTransition _ Nothing candidate = pure (Right candidate)
finishTransition env (Just prior) candidate =
  retireMemory env prior candidate >>= \case
    Right _ -> pure (Right candidate)
    Left (ResolutionConflict winner) ->
      retireMemory env candidate winner >>= \case
        Right _ -> pure (Left (ResolutionConflict winner))
        Left err -> pure (Left err)
    Left err -> pure (Left err)

recordCandidate :: PracticeReviewMemoryEnv -> MemoryId -> PracticeKey -> Kioku.Confidence -> Kioku.MemoryType -> Maybe MemoryId -> PracticeReviewMemoryEnvelope -> IO (Either ReviewMemoryError MemoryId)
recordCandidate PracticeReviewMemoryEnv {appEnv, agent = AgentDecl {name = agentName}, identity, sessionId} candidate practice confidence memoryType supersedes envelope = do
  recordedAt <- getCurrentTime
  let command =
        RecordMemoryData
          { memoryId = candidate,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor identity,
            ownerPrincipal = Nothing,
            agentId = agentNameText agentName,
            sessionId,
            scope = practiceReviewScope practice,
            memoryType,
            content = encodePracticeReviewMemory envelope,
            priority = 100,
            confidence,
            tags = practiceReviewTags envelope,
            supersedes,
            recordedAt
          }
  runAppIO appEnv (Memory.recordWithContext (shikigamiWriteContext identity) command) >>= \case
    Left storeError -> ioError (userError ("failed to record practice-review memory: " <> show storeError))
    Right (Right stored) -> pure (Right stored)
    Right (Left (MemoryConflict detail)) -> pure (Left (ReviewContentConflict candidate detail))
    Right (Left err) -> pure (Left (ReviewMemoryRefused (Text.pack (show err))))

retireMemory :: PracticeReviewMemoryEnv -> MemoryId -> MemoryId -> IO (Either ReviewMemoryError MemoryId)
retireMemory PracticeReviewMemoryEnv {appEnv, identity} loser winner = do
  supersededAt <- getCurrentTime
  let command =
        SupersedeMemoryData
          { memoryId = loser,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor identity,
            supersededBy = winner,
            supersededAt
          }
  runAppIO appEnv (Memory.supersedeWithContext (shikigamiWriteContext identity) command) >>= \case
    Left storeError -> ioError (userError ("failed to supersede practice-review memory: " <> show storeError))
    Right (Right stored) -> pure (Right stored)
    Right (Left err) ->
      lookupRecordedWinner appEnv loser >>= \case
        Left readError -> pure (Left readError)
        Right (Just recordedWinner) -> pure (Left (ResolutionConflict recordedWinner))
        Right Nothing -> pure (Left (ReviewMemoryRefused (Text.pack (show err))))

lookupRecordedWinner :: AppEnv -> MemoryId -> IO (Either ReviewMemoryError (Maybe MemoryId))
lookupRecordedWinner appEnv loser =
  readMemoryRow appEnv loser >>= \case
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (ReviewMemoryNotFound (idText loser)))
    Right (Just MemoryRow {supersededBy = Nothing}) -> pure (Right Nothing)
    Right (Just MemoryRow {supersededBy = Just winnerText}) ->
      case parseId winnerText of
        Left err -> pure (Left (ReviewMemoryMalformed (idText loser) err))
        Right winner -> pure (Right (Just winner))

loadEnvelope :: PracticeReviewMemoryEnv -> MemoryId -> IO (Either ReviewMemoryError PracticeReviewMemoryEnvelope)
loadEnvelope PracticeReviewMemoryEnv {appEnv} memoryId =
  fmap
    ( \case
        Left err -> Left err
        Right Nothing -> Left (ReviewMemoryNotFound (idText memoryId))
        Right (Just MemoryRow {content}) ->
          firstReviewError (idText memoryId) (decodePracticeReviewMemory content)
    )
    (readMemoryRow appEnv memoryId)

readMemoryRow :: AppEnv -> MemoryId -> IO (Either ReviewMemoryError (Maybe MemoryRow))
readMemoryRow appEnv memoryId =
  runAppIO appEnv (Memory.getMemoryRowById shikigamiMemorySpace memoryId) >>= \case
    Left storeError -> ioError (userError ("failed to read practice-review memory: " <> show storeError))
    Right (Left readError) -> pure (Left (ReviewMemoryRefused (Text.pack (show readError))))
    Right (Right row) -> pure (Right row)

firstReviewError :: Text -> Either Text value -> Either ReviewMemoryError value
firstReviewError memoryId = either (Left . ReviewMemoryMalformed memoryId) Right

verdictConfidence :: ValidatedPracticeReviewVerdict -> Kioku.Confidence
verdictConfidence validated =
  let PracticeReviewVerdict {confidence} = validatedVerdictValue validated
      percentage = confidencePercent confidence
   in if percentage >= 80
        then Kioku.HighConfidence
        else
          if percentage >= 50
            then Kioku.MediumConfidence
            else Kioku.LowConfidence

resolutionMemoryType :: ResolutionOutcome -> Kioku.MemoryType
resolutionMemoryType = \case
  Accepted -> Kioku.MemoryConstraint
  Narrowed -> Kioku.MemoryConstraint
  Rejected -> Kioku.MemoryFact
  Superseded -> Kioku.MemoryFact

recallPracticeReviewsIO :: PracticeReviewMemoryEnv -> ReviewRecallContext -> IO RecalledPracticeReviews
recallPracticeReviewsIO PracticeReviewMemoryEnv {appEnv} context@ReviewRecallContext {practice} =
  runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (practiceReviewScope practice)) >>= \case
    Left storeError -> ioError (userError ("failed to recall practice-review memories: " <> show storeError))
    Right (Left readError) -> ioError (userError ("failed to recall practice-review memories: " <> show readError))
    Right (Right rows) -> pure (classifyActiveRows context rows)

classifyActiveRows :: ReviewRecallContext -> [MemoryRow] -> RecalledPracticeReviews
classifyActiveRows context rows =
  RecalledPracticeReviews
    { guiding = fmap snd (sortOn fst guidingWithKeys),
      doNotRepeat = fmap snd (sortOn fst rejectedWithKeys),
      pending = fmap snd (sortOn fst pendingWithKeys),
      retired = fmap snd (sortOn fst retiredWithKeys),
      diagnostics = sortOn diagnosticKey malformed
    }
  where
    classified = classifyRow context <$> rows
    guidingWithKeys = [(key, value) | GuidingRow key value <- classified]
    rejectedWithKeys = [(key, value) | RejectedRow key value <- classified]
    pendingWithKeys = [(key, value) | PendingRow key value <- classified]
    retiredWithKeys = [(key, value) | RetiredRow key value <- classified]
    malformed = [value | DiagnosticRow value <- classified]
    diagnosticKey ReviewMemoryDiagnostic {memoryId, code} = (memoryId, code)

data ClassifiedRow
  = GuidingRow !(Text, Text) !AdjudicatedPracticeReview
  | RejectedRow !(Text, Text) !AdjudicatedPracticeReview
  | PendingRow !(Text, Text) !ValidatedPracticeReviewVerdict
  | RetiredRow !(Text, Text) !AdjudicatedPracticeReview
  | IgnoredRow
  | DiagnosticRow !ReviewMemoryDiagnostic

classifyRow :: ReviewRecallContext -> MemoryRow -> ClassifiedRow
classifyRow context@ReviewRecallContext {practice = wantedPractice} MemoryRow {memoryId, content} =
  case decodePracticeReviewMemory content of
    Left err -> DiagnosticRow (ReviewMemoryDiagnostic memoryId "invalid-envelope" err)
    Right (ProvisionalReview verdict) -> classifyVerdict verdict (classifyProvisional verdict)
    Right (ResolvedReview verdict resolution) -> classifyVerdict verdict (classifyResolved verdict resolution)
  where
    classifyVerdict verdict classified =
      let PracticeReviewVerdict {practice} = validatedVerdictValue verdict
       in if matchesPractices [practice] wantedPractice
            then classified
            else DiagnosticRow (ReviewMemoryDiagnostic memoryId "scope-mismatch" "envelope practice does not match the queried practice scope")

    classifyProvisional verdict =
      if verdictMatchesContext context verdict
        then PendingRow (reviewSortKey verdict memoryId) verdict
        else IgnoredRow

    classifyResolved verdict resolution =
      let adjudicated = AdjudicatedPracticeReview {verdict, resolution}
          PracticeReviewResolution {outcome, resultingApplicability} = validatedResolutionValue resolution
          matchesOriginal = verdictMatchesContext context verdict
       in case outcome of
            Accepted
              | maybe False (`appliesTo` context) resultingApplicability -> GuidingRow (reviewSortKey verdict memoryId) adjudicated
            Narrowed
              | maybe False (`appliesTo` context) resultingApplicability -> GuidingRow (reviewSortKey verdict memoryId) adjudicated
            Rejected
              | matchesOriginal -> RejectedRow (reviewSortKey verdict memoryId) adjudicated
            Superseded
              | matchesOriginal -> RetiredRow (reviewSortKey verdict memoryId) adjudicated
            _ -> IgnoredRow

verdictMatchesContext :: ReviewRecallContext -> ValidatedPracticeReviewVerdict -> Bool
verdictMatchesContext context validated =
  let PracticeReviewVerdict {practice, applicability} = validatedVerdictValue validated
      ReviewRecallContext {practice = wantedPractice} = context
   in matchesPractices [practice] wantedPractice && appliesTo applicability context

reviewSortKey :: ValidatedPracticeReviewVerdict -> Text -> (Text, Text)
reviewSortKey validated memoryId =
  let PracticeReviewVerdict {reviewId} = validatedVerdictValue validated
   in (reviewIdText reviewId, memoryId)

recallPracticeReviewChainIO :: PracticeReviewMemoryEnv -> ReviewId -> IO PracticeReviewChain
recallPracticeReviewChainIO PracticeReviewMemoryEnv {appEnv} reviewId =
  runAppIO appEnv (Memory.getSupersessionChain shikigamiMemorySpace (provisionalMemoryId reviewId)) >>= \case
    Left storeError -> ioError (userError ("failed to read practice-review chain: " <> show storeError))
    Right (Left readError) ->
      pure
        PracticeReviewChain
          { entries = [],
            diagnostics = [ReviewMemoryDiagnostic (idText (provisionalMemoryId reviewId)) "chain-read-failed" (Text.pack (show readError))]
          }
    Right (Right rows) -> do
      let orderedEntries = chainEntry <$> sortOn chainRowKey rows
          diagnostics = [entryDiagnostic | PracticeReviewChainEntry {diagnostic = Just entryDiagnostic} <- orderedEntries]
      pure PracticeReviewChain {entries = orderedEntries, diagnostics}
  where
    chainRowKey MemoryRow {createdAt, memoryId} = (createdAt, memoryId)

chainEntry :: MemoryRow -> PracticeReviewChainEntry
chainEntry MemoryRow {memoryId, status, supersededBy, supersedes, content} =
  case decodePracticeReviewMemory content of
    Right envelope ->
      PracticeReviewChainEntry
        { memoryId,
          status,
          supersededBy,
          supersedes,
          envelope = Just envelope,
          diagnostic = Nothing
        }
    Left detail ->
      PracticeReviewChainEntry
        { memoryId,
          status,
          supersededBy,
          supersedes,
          envelope = Nothing,
          diagnostic = Just (ReviewMemoryDiagnostic memoryId "invalid-envelope" detail)
        }
