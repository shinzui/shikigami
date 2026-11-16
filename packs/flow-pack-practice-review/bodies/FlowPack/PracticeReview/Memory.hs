{-# LANGUAGE TypeFamilies #-}

-- | Replay-safe persistence and adjudication for architecture-practice reviews.
--
-- The public effect is deliberately narrower than the generic Flow memory
-- capability. A review transition owns logical ids, typed envelopes, an exact
-- practice scope, and Kioku's separate record/retire protocol. Flow code gets
-- these operations and no Kioku environment or IO capability.
--
-- This module is the effect and its vocabulary, which the flow body sees.
-- The interpreter that journals each operation under a fixed label lives in
-- "FlowPack.PracticeReview.Memory.Store", in the pack's main library.
module FlowPack.PracticeReview.Memory
  ( PracticeReviewMemory (..),
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
    practiceReviewTags,
    encodePracticeReviewMemory,
    decodePracticeReviewMemory,
    appliesTo,
    matchesPractices,
    normalizeToken,
    ReviewIdentityRef,
    allocatedReviewId,
    reserveReviewIdentity,
    ResolvedPracticeReview (..),
    rememberProvisional,
    resolveReview,
    recallPracticeReviews,
    recallPracticeReviewChain,
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
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import FlowPack.PracticeReview.IdentityRef (ReviewIdentityRef, allocatedReviewId)
import FlowPack.PracticeReview.Types
  ( Applicability (..),
    ContentReference (..),
    DependencyName,
    EvidenceItem (..),
    PracticeKey,
    PracticeReviewResolution (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ResolutionId,
    ReviewId,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    ValidatedResolutionRequest,
    dependencyNameText,
    practiceKeyText,
    resolutionIdText,
    reviewIdText,
    validateResolution,
    validateVerdict,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Kioku.Id (MemoryId)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Flow.Sdk (Dispatch (Dynamic), DispatchOf, Eff, Effect, send, (:>))
import Shikigami.Prelude (Generic, eventAesonOptions, genericParseJSON, genericToJSON)
import Shikigami.Repository (RelativePath, relativePathText, repositoryIdText)

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
    other -> error ("FlowPack.PracticeReview.Memory: expected enum JSON string, got " <> show other)

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
