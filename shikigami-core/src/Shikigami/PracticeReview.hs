{-# LANGUAGE DataKinds #-}

-- | Versioned, pure contracts for architecture-practice review.
--
-- This module deliberately contains no workflow, persistence, model-provider,
-- or sink behavior. 'Shikigami.Agent.RunJob.RunJob' carries the JSON payload;
-- the durable review flow will decode and validate it at its own boundary.
module Shikigami.PracticeReview
  ( practiceReviewSchemaVersion,
    ReviewId,
    parseReviewId,
    reviewIdText,
    PracticeKey,
    parsePracticeKey,
    practiceKeyText,
    OwnerPrincipal,
    parseOwnerPrincipal,
    ownerPrincipalText,
    ProjectRef (..),
    DependencyName,
    parseDependencyName,
    dependencyNameText,
    DocumentId,
    parseDocumentId,
    documentIdText,
    TriggerKey,
    parseTriggerKey,
    triggerKeyText,
    ResolutionKey,
    parseResolutionKey,
    resolutionKeyText,
    Materiality (..),
    RevisionChangeKind (..),
    RevisionRange (..),
    Applicability (..),
    ReviewMode (..),
    ReviewOwners (..),
    RegisteredPracticeReference (..),
    RegisteredUpstreamProject (..),
    PracticeAdoptionBinding (..),
    PracticeReviewTriggerKind (..),
    ChangedReference (..),
    PracticeReviewTrigger (..),
    ResolutionId,
    parseResolutionId,
    resolutionIdText,
    EvidenceId,
    parseEvidenceId,
    evidenceIdText,
    ClaimId,
    parseClaimId,
    claimIdText,
    ContentHash,
    parseContentHash,
    contentHashText,
    Confidence,
    parseConfidence,
    confidencePercent,
    zeroConfidence,
    evidenceProblemClaimId,
    sourceEvidenceIdV2,
    ClaimKind (..),
    EvidenceRole (..),
    ContentReference (..),
    EvidenceItem (..),
    PracticeReviewClaim (..),
    ReviewLineage (..),
    RecommendedOwnerRole (..),
    RecommendedOwner (..),
    ExceptionApproval (..),
    ReReviewCondition (..),
    PracticeReviewClassification (..),
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
    PracticeReviewResolution (..),
    ReviewContractError (..),
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    ValidatedPracticeReviewResolution,
    validatedTriggerValue,
    validatedVerdictValue,
    validatedResolutionValue,
    PracticeReviewResolutionRequest (..),
    ValidatedResolutionRequest,
    validateResolutionRequest,
    validatedResolutionRequestValue,
    allocateResolution,
    validateTrigger,
    validateVerdict,
    validateResolution,
  )
where

import Data.Aeson (Value (Object), withObject, withText, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (SessionId, idText)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.PracticeReview.Identity
import Shikigami.Prelude hiding ((.=))
import Shikigami.Repository (RelativePath, RepoRef (..), RepositoryId (..), Revision, relativePathText, revisionText)
import Shikigami.Sink.Coordinate (parseSinkSession)

-- | The only schema version accepted by the first contract release.
practiceReviewSchemaVersion :: FormatVersion scope
practiceReviewSchemaVersion = V1

-- | Stable key for one registered architecture practice.
newtype PracticeKey = PracticeKey {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Resolved identity of a person or approved artifact workflow.
newtype OwnerPrincipal = OwnerPrincipal {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Human-readable project name beside its canonical Mori repository identity.
data ProjectRef = ProjectRef
  { name :: !Text,
    repository :: !RepositoryId
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProjectRef where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ProjectRef where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Whether the changed repository object is new or replaces prior content.
data RevisionChangeKind = Added | Modified
  deriving stock (Eq, Show, Generic)

instance ToJSON RevisionChangeKind where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON RevisionChangeKind where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | Immutable endpoints for one repository change.
--
-- Validation later enforces that 'Added' has no @before@ revision and
-- 'Modified' has one.
data RevisionRange = RevisionRange
  { changeKind :: !RevisionChangeKind,
    before :: !(Maybe Revision),
    head :: !Revision
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RevisionRange where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON RevisionRange where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | The bounded scope within which an adoption, exception, or resolution may
-- guide a later review. At least one dimension must be present when a bounded
-- applicability is semantically required.
data Applicability = Applicability
  { projects :: ![ProjectRef],
    paths :: ![RelativePath],
    dependencies :: ![DependencyName],
    practices :: ![PracticeKey]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Applicability where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON Applicability where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | The initial release can advise but cannot block or modify a repository.
data ReviewMode = Advisory
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewMode where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON ReviewMode where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | Resolved owners supplied by the adoption graph.
data ReviewOwners = ReviewOwners
  { targetOwner :: !OwnerPrincipal,
    practiceOwner :: !OwnerPrincipal,
    triageOwner :: !OwnerPrincipal,
    exceptionApprover :: !(Maybe OwnerPrincipal)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewOwners where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ReviewOwners where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Registered practice documents read at one pinned reference revision.
data RegisteredPracticeReference = RegisteredPracticeReference
  { project :: !ProjectRef,
    provenance :: !RepoRef,
    documentIds :: ![DocumentId]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RegisteredPracticeReference where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON RegisteredPracticeReference where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Registered upstream source whose compatible revision will be selected by
-- evidence acquisition from a target dependency pin.
data RegisteredUpstreamProject = RegisteredUpstreamProject
  { project :: !ProjectRef,
    dependency :: !DependencyName
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RegisteredUpstreamProject where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON RegisteredUpstreamProject where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | One project's declared adoption of a registered practice.
data PracticeAdoptionBinding = PracticeAdoptionBinding
  { practice :: !PracticeKey,
    references :: ![RegisteredPracticeReference],
    claimedApplicability :: !Applicability,
    mode :: !ReviewMode,
    owners :: !ReviewOwners,
    upstreamProjects :: ![RegisteredUpstreamProject]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeAdoptionBinding where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeAdoptionBinding where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Whether the target changed or a registered practice reference changed and
-- therefore asks for prior targets to be reviewed again.
data PracticeReviewTriggerKind = TargetChange | ReferenceChange
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewTriggerKind where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON PracticeReviewTriggerKind where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | The reference-side change that caused a re-review request.
data ChangedReference = ChangedReference
  { project :: !ProjectRef,
    range :: !RevisionRange,
    changedPaths :: ![RelativePath]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ChangedReference where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ChangedReference where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | The version-1 trigger accepted from Mori.
--
-- Specialist selection is Shikigami's responsibility. The decoder therefore
-- rejects @specialist@ and @candidates@ keys instead of relying on Aeson's
-- default unknown-field behavior, which would silently discard them.
data PracticeReviewTrigger = PracticeReviewTrigger
  { schemaVersion :: !(FormatVersion "practice-review-trigger"),
    triggerKind :: !PracticeReviewTriggerKind,
    idempotencyKey :: !TriggerKey,
    target :: !ProjectRef,
    targetRange :: !RevisionRange,
    changedDecisionPaths :: ![RelativePath],
    adoptions :: ![PracticeAdoptionBinding],
    referenceChange :: !(Maybe ChangedReference),
    priorReviewId :: !(Maybe ReviewId)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewTrigger where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewTrigger where
  parseJSON value@(Object object)
    | KeyMap.member "specialist" object = fail "PracticeReviewTrigger must not name a specialist"
    | KeyMap.member "candidates" object = fail "PracticeReviewTrigger must not name specialist candidates"
    | otherwise = genericParseJSON practiceReviewAesonOptions value
  parseJSON value = genericParseJSON practiceReviewAesonOptions value

-- | Identity of one pinned evidence item within a verdict.
newtype EvidenceId = EvidenceId {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Identity of one claim within a verdict.
newtype ClaimId = ClaimId {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Digest supplied by the revision-pinned content plane.
newtype ContentHash = ContentHash {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Integer confidence percentage. Validation accepts values from 0 through
-- 100 inclusive.
newtype Confidence = Confidence {value :: Int}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | Whether cited content states a claim directly or supports a conclusion.
data ClaimKind = Fact | Inference
  deriving stock (Eq, Show, Generic)

instance ToJSON ClaimKind where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON ClaimKind where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | Which bounded evidence collection an item belongs to.
data EvidenceRole = TargetEvidence | ReferenceEvidence | UpstreamEvidence
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceRole where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON EvidenceRole where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | One immutable repository path and its content digest.
data ContentReference = ContentReference
  { project :: !ProjectRef,
    provenance :: !RepoRef,
    path :: !RelativePath,
    contentHash :: !ContentHash
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ContentReference where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ContentReference where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | A pinned content identity that claims can cite by 'EvidenceId'.
data EvidenceItem = EvidenceItem
  { evidenceId :: !EvidenceId,
    role :: !EvidenceRole,
    content :: !ContentReference
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceItem where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON EvidenceItem where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | One material or contextual statement in a verdict.
data PracticeReviewClaim = PracticeReviewClaim
  { claimId :: !ClaimId,
    kind :: !ClaimKind,
    statement :: !Text,
    material :: !Materiality,
    evidenceIds :: ![EvidenceId]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewClaim where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewClaim where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Parent router and child specialist execution lineage.
data ReviewLineage = ReviewLineage
  { parentSessionId :: !SessionId,
    childSessionId :: !SessionId,
    parentWorkflowId :: !WorkflowId,
    childWorkflowId :: !WorkflowId,
    priorReviewId :: !(Maybe ReviewId)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewLineage where
  toJSON value = Aeson.object (["parentSessionId" .= value.parentSessionId, "childSessionId" .= value.childSessionId, "parentWorkflowId" .= value.parentWorkflowId.unWorkflowId, "childWorkflowId" .= value.childWorkflowId.unWorkflowId] <> maybe [] (\prior -> ["priorReviewId" .= prior]) value.priorReviewId)

instance FromJSON ReviewLineage where
  parseJSON = withObject "review lineage" \fields ->
    ReviewLineage <$> (fields .: "parentSessionId" >>= session) <*> (fields .: "childSessionId" >>= session) <*> (WorkflowId <$> fields .: "parentWorkflowId") <*> (WorkflowId <$> fields .: "childWorkflowId") <*> fields .:? "priorReviewId"
    where
      session = either (fail . Text.unpack) pure . parseSinkSession . Text.strip

-- | Closed semantic role selected for attention routing.
data RecommendedOwnerRole
  = TargetOwner
  | PracticeOwner
  | TriageOwner
  | JointOwners
  | ExceptionApprover
  deriving stock (Eq, Show, Generic)

instance ToJSON RecommendedOwnerRole where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON RecommendedOwnerRole where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | A semantic owner role plus the already-resolved principals it denotes.
data RecommendedOwner = RecommendedOwner
  { role :: !RecommendedOwnerRole,
    principals :: ![OwnerPrincipal]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RecommendedOwner where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON RecommendedOwner where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Whether a legitimate exception still needs explicit approval.
data ExceptionApproval = NoApproval | ApprovalRequired
  deriving stock (Eq, Show, Generic)

instance ToJSON ExceptionApproval where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON ExceptionApproval where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | What material change should cause this conclusion to be reviewed again.
data ReReviewCondition = ReReviewCondition
  { condition :: !Text,
    watches :: ![RepoRef]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReReviewCondition where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ReReviewCondition where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | The complete semantic result vocabulary. Runtime and delivery failures are
-- deliberately not constructors here.
data PracticeReviewClassification
  = Consistent
  | TargetSuspect
  | ReferenceSuspect
  | LegitimateException
  | Unresolved
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewClassification where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON PracticeReviewClassification where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | A provisional, evidence-bearing specialist verdict.
data PracticeReviewVerdict = PracticeReviewVerdict
  { schemaVersion :: !(FormatVersion "practice-review-verdict"),
    reviewId :: !ReviewId,
    triggerIdempotencyKey :: !TriggerKey,
    practice :: !PracticeKey,
    specialist :: !AgentName,
    lineage :: !ReviewLineage,
    targetEvidence :: ![EvidenceItem],
    referenceEvidence :: ![EvidenceItem],
    upstreamEvidence :: ![EvidenceItem],
    claims :: ![PracticeReviewClaim],
    confidence :: !Confidence,
    routingRationale :: !Text,
    classification :: !PracticeReviewClassification,
    recommendedOwner :: !(Maybe RecommendedOwner),
    recommendedAction :: !Text,
    exceptionApproval :: !ExceptionApproval,
    reReviewCondition :: !ReReviewCondition,
    applicability :: !Applicability
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewVerdict where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewVerdict where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | The only outcomes an explicit resolver can record.
data ResolutionOutcome = Accepted | Rejected | Narrowed | Superseded
  deriving stock (Eq, Show, Generic)

instance ToJSON ResolutionOutcome where toJSON = genericToJSON practiceReviewEnumAesonOptions

instance FromJSON ResolutionOutcome where parseJSON = genericParseJSON practiceReviewEnumAesonOptions

-- | An authorized command that adjudicates one provisional review.
data PracticeReviewResolution = PracticeReviewResolution
  { schemaVersion :: !(FormatVersion "practice-review-resolution"),
    resolutionId :: !ResolutionId,
    idempotencyKey :: !ResolutionKey,
    reviewId :: !ReviewId,
    outcome :: !ResolutionOutcome,
    resolver :: !OwnerPrincipal,
    reason :: !Text,
    resolvedAt :: !UTCTime,
    resultingApplicability :: !(Maybe Applicability),
    supersedingReviewId :: !(Maybe ReviewId)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewResolution where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewResolution where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Authorized command before its owner allocates a resolution entity.
data PracticeReviewResolutionRequest = PracticeReviewResolutionRequest
  { schemaVersion :: !(FormatVersion "practice-review-resolution"),
    idempotencyKey :: !ResolutionKey,
    reviewId :: !ReviewId,
    outcome :: !ResolutionOutcome,
    resolver :: !OwnerPrincipal,
    reason :: !Text,
    resolvedAt :: !UTCTime,
    resultingApplicability :: !(Maybe Applicability),
    supersedingReviewId :: !(Maybe ReviewId)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewResolutionRequest where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewResolutionRequest where
  parseJSON = withObject "PracticeReviewResolutionRequest" \value -> do
    let allowed = ["schemaVersion", "idempotencyKey", "reviewId", "outcome", "resolver", "reason", "resolvedAt", "resultingApplicability", "supersedingReviewId"]
    unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys value)) (fail "unknown resolution request field")
    PracticeReviewResolutionRequest <$> value .: "schemaVersion" <*> value .: "idempotencyKey" <*> value .: "reviewId" <*> value .: "outcome" <*> value .: "resolver" <*> value .: "reason" <*> value .: "resolvedAt" <*> value .:? "resultingApplicability" <*> value .:? "supersedingReviewId"

newtype ValidatedResolutionRequest = ValidatedResolutionRequest PracticeReviewResolutionRequest
  deriving stock (Eq, Show)

validatedResolutionRequestValue :: ValidatedResolutionRequest -> PracticeReviewResolutionRequest
validatedResolutionRequestValue (ValidatedResolutionRequest request) = request

validateResolutionRequest :: PracticeReviewResolutionRequest -> Either (NonEmpty ReviewContractError) ValidatedResolutionRequest
validateResolutionRequest PracticeReviewResolutionRequest {schemaVersion, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId} =
  toValidationResult
    ( schemaErrors "resolution" schemaVersion
        <> blankErrors "resolution.idempotencyKey" (resolutionKeyText idempotencyKey)
        <> blankErrors "resolution.reason" reason
        <> resolutionOutcomeErrors outcome resultingApplicability supersedingReviewId reviewId
    )
    (ValidatedResolutionRequest PracticeReviewResolutionRequest {schemaVersion, idempotencyKey = normalizeResolutionKey idempotencyKey, reviewId, outcome, resolver = normalizeOwnerPrincipal resolver, reason, resolvedAt, resultingApplicability = fmap normalizeApplicability resultingApplicability, supersedingReviewId})

allocateResolution :: ResolutionId -> ValidatedResolutionRequest -> ValidatedPracticeReviewResolution
allocateResolution resolutionId (ValidatedResolutionRequest PracticeReviewResolutionRequest {schemaVersion, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId}) =
  ValidatedPracticeReviewResolution PracticeReviewResolution {schemaVersion, resolutionId, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId}

-- | One precise reason a raw contract value was rejected.
data ReviewContractError = ReviewContractError
  { field :: !Text,
    message :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A trigger whose schema, identities, ranges, adoption bindings, and routing
-- boundary have been checked and normalized.
newtype ValidatedPracticeReviewTrigger = ValidatedPracticeReviewTrigger PracticeReviewTrigger
  deriving stock (Eq, Show)

-- | A verdict whose evidence graph and classification invariants have been
-- checked and normalized.
newtype ValidatedPracticeReviewVerdict = ValidatedPracticeReviewVerdict PracticeReviewVerdict
  deriving stock (Eq, Show)

-- | A resolution whose allocated identity and outcome-specific fields have
-- been checked and normalized.
newtype ValidatedPracticeReviewResolution = ValidatedPracticeReviewResolution PracticeReviewResolution
  deriving stock (Eq, Show)

validatedTriggerValue :: ValidatedPracticeReviewTrigger -> PracticeReviewTrigger
validatedTriggerValue (ValidatedPracticeReviewTrigger trigger) = trigger

validatedVerdictValue :: ValidatedPracticeReviewVerdict -> PracticeReviewVerdict
validatedVerdictValue (ValidatedPracticeReviewVerdict verdict) = verdict

validatedResolutionValue :: ValidatedPracticeReviewResolution -> PracticeReviewResolution
validatedResolutionValue (ValidatedPracticeReviewResolution resolution) = resolution

uuidText :: [Text] -> Text
uuidText identityParts =
  UUID.toText
    ( UUIDv5.generateNamed
        practiceReviewNamespace
        (ByteString.unpack (TextEncoding.encodeUtf8 (lengthPrefixed identityParts)))
    )

practiceReviewNamespace :: UUID.UUID
practiceReviewNamespace =
  UUIDv5.generateNamed
    UUIDv5.namespaceURL
    (ByteString.unpack (TextEncoding.encodeUtf8 "mori://shinzui/shikigami/contracts/practice-review/v1"))

lengthPrefixed :: [Text] -> Text
lengthPrefixed = Text.intercalate "|" . fmap (\part -> Text.pack (show (Text.length part)) <> ":" <> part)

normalizeOpaqueKey :: Text -> Text
normalizeOpaqueKey = Text.strip

normalizeNamedKey :: Text -> Text
normalizeNamedKey = Text.toCaseFold . Text.strip

-- | Validate and normalize a raw trigger, accumulating every error that can be
-- found without external state.
validateTrigger :: PracticeReviewTrigger -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewTrigger
validateTrigger trigger =
  toValidationResult
    (triggerErrors trigger)
    (ValidatedPracticeReviewTrigger (normalizeTrigger trigger))

-- | Validate and normalize a raw verdict, including its evidence citation
-- graph and classification-specific owner rules.
validateVerdict :: PracticeReviewVerdict -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewVerdict
validateVerdict verdict =
  toValidationResult
    (verdictErrors verdict)
    (ValidatedPracticeReviewVerdict (normalizeVerdict verdict))

-- | Validate and normalize an explicit resolution command.
validateResolution :: PracticeReviewResolution -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewResolution
validateResolution resolution =
  toValidationResult
    (resolutionErrors resolution)
    (ValidatedPracticeReviewResolution (normalizeResolution resolution))

toValidationResult :: [ReviewContractError] -> value -> Either (NonEmpty ReviewContractError) value
toValidationResult [] value = Right value
toValidationResult (problem : problems) _ = Left (problem :| problems)

contractError :: Text -> Text -> ReviewContractError
contractError = ReviewContractError

check :: Bool -> Text -> Text -> [ReviewContractError]
check condition fieldName problem = [contractError fieldName problem | condition]

blankErrors :: Text -> Text -> [ReviewContractError]
blankErrors fieldName raw = check (Text.null (Text.strip raw)) fieldName "must not be empty"

schemaErrors :: Text -> FormatVersion scope -> [ReviewContractError]
schemaErrors document actual =
  check
    (actual /= practiceReviewSchemaVersion)
    (document <> ".schemaVersion")
    ( "unsupported schema version "
        <> Text.pack (show actual)
        <> "; expected "
        <> Text.pack (show practiceReviewSchemaVersion)
    )

projectErrors :: Text -> ProjectRef -> [ReviewContractError]
projectErrors prefix ProjectRef {name, repository = RepositoryId repositoryId} =
  blankErrors (prefix <> ".name") name
    <> blankErrors (prefix <> ".repository") repositoryId

repoRefErrors :: Text -> RepoRef -> [ReviewContractError]
repoRefErrors prefix RepoRef {repository = RepositoryId repositoryId} =
  blankErrors (prefix <> ".repository") repositoryId

revisionRangeErrors :: Text -> RevisionRange -> [ReviewContractError]
revisionRangeErrors prefix RevisionRange {changeKind, before} =
  case changeKind of
    Added -> check (isJust before) (prefix <> ".before") "must be absent for an added object"
    Modified -> check (isNothing before) (prefix <> ".before") "is required for a modified object"

applicabilityErrors :: Bool -> Text -> Applicability -> [ReviewContractError]
applicabilityErrors requireBounded prefix Applicability {projects, paths, dependencies, practices} =
  check
    (requireBounded && null projects && null paths && null dependencies && null practices)
    prefix
    "must bound at least one project, path, dependency, or practice"
    <> concatMap (uncurry projectErrors) (indexedFields (prefix <> ".projects") projects)
    <> concatMap (uncurry blankErrors) (indexedFields (prefix <> ".dependencies") (map dependencyNameText dependencies))

triggerErrors :: PracticeReviewTrigger -> [ReviewContractError]
triggerErrors
  PracticeReviewTrigger
    { schemaVersion,
      triggerKind,
      idempotencyKey,
      target,
      targetRange,
      changedDecisionPaths,
      adoptions,
      referenceChange
    } =
    schemaErrors "trigger" schemaVersion
      <> blankErrors "trigger.idempotencyKey" (triggerKeyText idempotencyKey)
      <> projectErrors "trigger.target" target
      <> revisionRangeErrors "trigger.targetRange" targetRange
      <> check (null changedDecisionPaths) "trigger.changedDecisionPaths" "must contain at least one path"
      <> check (null adoptions) "trigger.adoptions" "must contain at least one practice adoption"
      <> concatMap (uncurry adoptionErrors) (indexedFields "trigger.adoptions" adoptions)
      <> referenceChangeErrors triggerKind referenceChange

referenceChangeErrors :: PracticeReviewTriggerKind -> Maybe ChangedReference -> [ReviewContractError]
referenceChangeErrors TargetChange Nothing = []
referenceChangeErrors TargetChange (Just changed) =
  changedReferenceErrors changed
    <> [contractError "trigger.referenceChange" "must be absent for target-change"]
referenceChangeErrors ReferenceChange Nothing =
  [contractError "trigger.referenceChange" "is required for reference-change"]
referenceChangeErrors ReferenceChange (Just changed@ChangedReference {range = RevisionRange {changeKind}}) =
  changedReferenceErrors changed
    <> check (changeKind /= Modified) "trigger.referenceChange.range.changeKind" "must be modified"

changedReferenceErrors :: ChangedReference -> [ReviewContractError]
changedReferenceErrors ChangedReference {project, range, changedPaths} =
  projectErrors "trigger.referenceChange.project" project
    <> revisionRangeErrors "trigger.referenceChange.range" range
    <> check (null changedPaths) "trigger.referenceChange.changedPaths" "must contain at least one path"

adoptionErrors :: Text -> PracticeAdoptionBinding -> [ReviewContractError]
adoptionErrors
  prefix
  PracticeAdoptionBinding
    { references,
      claimedApplicability,
      mode,
      upstreamProjects
    } =
    check (null references) (prefix <> ".references") "must contain at least one registered reference"
      <> concatMap (uncurry registeredReferenceErrors) (indexedFields (prefix <> ".references") references)
      <> applicabilityErrors True (prefix <> ".claimedApplicability") claimedApplicability
      <> check (mode /= Advisory) (prefix <> ".mode") "version 1 supports advisory mode only"
      <> concatMap (uncurry upstreamProjectErrors) (indexedFields (prefix <> ".upstreamProjects") upstreamProjects)

registeredReferenceErrors :: Text -> RegisteredPracticeReference -> [ReviewContractError]
registeredReferenceErrors
  prefix
  RegisteredPracticeReference
    { project = project@ProjectRef {repository = projectRepository},
      provenance = provenance@RepoRef {repository = provenanceRepository},
      documentIds
    } =
    projectErrors (prefix <> ".project") project
      <> repoRefErrors (prefix <> ".provenance") provenance
      <> check
        (projectRepository /= provenanceRepository)
        (prefix <> ".provenance.repository")
        "must match the registered project repository"
      <> check (null documentIds) (prefix <> ".documentIds") "must contain at least one document id"
      <> concatMap (uncurry blankErrors) (indexedFields (prefix <> ".documentIds") (map documentIdText documentIds))

upstreamProjectErrors :: Text -> RegisteredUpstreamProject -> [ReviewContractError]
upstreamProjectErrors prefix RegisteredUpstreamProject {project, dependency} =
  projectErrors (prefix <> ".project") project
    <> blankErrors (prefix <> ".dependency") (dependencyNameText dependency)

verdictErrors :: PracticeReviewVerdict -> [ReviewContractError]
verdictErrors
  PracticeReviewVerdict
    { schemaVersion,
      triggerIdempotencyKey,
      specialist,
      lineage,
      targetEvidence,
      referenceEvidence,
      upstreamEvidence,
      claims,
      routingRationale,
      classification,
      recommendedOwner,
      recommendedAction,
      exceptionApproval,
      reReviewCondition,
      applicability
    } =
    schemaErrors "verdict" schemaVersion
      <> blankErrors "verdict.triggerIdempotencyKey" (triggerKeyText triggerIdempotencyKey)
      <> blankErrors "verdict.specialist" (agentNameText specialist)
      <> lineageErrors lineage
      <> check (classification /= Unresolved && null targetEvidence) "verdict.targetEvidence" "must contain pinned target evidence"
      <> check (classification /= Unresolved && null referenceEvidence) "verdict.referenceEvidence" "must contain pinned practice evidence"
      <> evidenceCollectionErrors TargetEvidence "verdict.targetEvidence" targetEvidence
      <> evidenceCollectionErrors ReferenceEvidence "verdict.referenceEvidence" referenceEvidence
      <> evidenceCollectionErrors UpstreamEvidence "verdict.upstreamEvidence" upstreamEvidence
      <> duplicateEvidenceErrors allEvidence
      <> concatMap (uncurry (claimErrors (classification == Unresolved) knownEvidence)) (indexedFields "verdict.claims" claims)
      <> duplicateClaimErrors claims
      <> blankErrors "verdict.routingRationale" routingRationale
      <> blankErrors "verdict.recommendedAction" recommendedAction
      <> recommendedOwnerErrors recommendedOwner
      <> classificationErrors classification recommendedOwner exceptionApproval applicability claims
      <> reReviewErrors reReviewCondition
      <> applicabilityErrors False "verdict.applicability" applicability
    where
      allEvidence = targetEvidence <> referenceEvidence <> upstreamEvidence
      knownEvidence = Set.fromList [evidenceId | EvidenceItem {evidenceId} <- allEvidence]

lineageErrors :: ReviewLineage -> [ReviewContractError]
lineageErrors ReviewLineage {parentSessionId, childSessionId, parentWorkflowId, childWorkflowId} =
  blankErrors "verdict.lineage.parentSessionId" (idText parentSessionId)
    <> blankErrors "verdict.lineage.childSessionId" (idText childSessionId)
    <> blankErrors "verdict.lineage.parentWorkflowId" parentWorkflowId.unWorkflowId
    <> blankErrors "verdict.lineage.childWorkflowId" childWorkflowId.unWorkflowId

evidenceCollectionErrors :: EvidenceRole -> Text -> [EvidenceItem] -> [ReviewContractError]
evidenceCollectionErrors expected prefix =
  concatMap (uncurry (evidenceItemErrors expected)) . indexedFields prefix

evidenceItemErrors :: EvidenceRole -> Text -> EvidenceItem -> [ReviewContractError]
evidenceItemErrors expected prefix EvidenceItem {role, content} =
  check (role /= expected) (prefix <> ".role") "does not match its evidence collection"
    <> contentReferenceErrors (prefix <> ".content") content

contentReferenceErrors :: Text -> ContentReference -> [ReviewContractError]
contentReferenceErrors
  prefix
  ContentReference
    { project = project@ProjectRef {repository = projectRepository},
      provenance = provenance@RepoRef {repository = provenanceRepository}
    } =
    projectErrors (prefix <> ".project") project
      <> repoRefErrors (prefix <> ".provenance") provenance
      <> check
        (projectRepository /= provenanceRepository)
        (prefix <> ".provenance.repository")
        "must match the content project repository"

duplicateEvidenceErrors :: [EvidenceItem] -> [ReviewContractError]
duplicateEvidenceErrors items =
  [ contractError "verdict.evidenceId" ("duplicate evidence id: " <> evidence)
  | EvidenceId evidence <- duplicateValues [evidenceId | EvidenceItem {evidenceId} <- items]
  ]

duplicateClaimErrors :: [PracticeReviewClaim] -> [ReviewContractError]
duplicateClaimErrors claims =
  [ contractError "verdict.claimId" ("duplicate claim id: " <> claim)
  | ClaimId claim <- duplicateValues [claimId | PracticeReviewClaim {claimId} <- claims]
  ]

claimErrors :: Bool -> Set.Set EvidenceId -> Text -> PracticeReviewClaim -> [ReviewContractError]
claimErrors allowProblemDerived known prefix PracticeReviewClaim {statement, evidenceIds} =
  blankErrors (prefix <> ".statement") statement
    <> check (not allowProblemDerived && null evidenceIds) (prefix <> ".evidenceIds") "must cite at least one evidence item"
    <> [ contractError (prefix <> ".evidenceIds") ("references unknown evidence id: " <> evidence)
       | evidenceId@(EvidenceId evidence) <- evidenceIds,
         Set.notMember evidenceId known
       ]

recommendedOwnerErrors :: Maybe RecommendedOwner -> [ReviewContractError]
recommendedOwnerErrors Nothing = []
recommendedOwnerErrors (Just RecommendedOwner {role, principals}) =
  check (null principals) "verdict.recommendedOwner.principals" "must contain at least one principal"
    <> check (role == JointOwners && length principals < 2) "verdict.recommendedOwner.principals" "joint-owners requires at least two principals"
    <> check (role /= JointOwners && length principals /= 1) "verdict.recommendedOwner.principals" "this owner role requires exactly one principal"

classificationErrors :: PracticeReviewClassification -> Maybe RecommendedOwner -> ExceptionApproval -> Applicability -> [PracticeReviewClaim] -> [ReviewContractError]
classificationErrors classification recommendedOwner exceptionApproval applicability claims =
  case classification of
    Consistent ->
      check (isJust recommendedOwner) "verdict.recommendedOwner" "must be absent for consistent"
        <> noExceptionApproval
    TargetSuspect ->
      expectedRole TargetOwner
        <> materialClaimRequired
        <> noExceptionApproval
    ReferenceSuspect ->
      expectedRole PracticeOwner
        <> materialClaimRequired
        <> noExceptionApproval
    Unresolved ->
      unresolvedOwner
        <> noExceptionApproval
    LegitimateException ->
      applicabilityErrors True "verdict.applicability" applicability
        <> case exceptionApproval of
          NoApproval -> check (isJust recommendedOwner) "verdict.recommendedOwner" "must be absent when exception approval is not required"
          ApprovalRequired -> expectedRole ExceptionApprover
  where
    roleOf RecommendedOwner {role} = role
    expectedRole expected =
      check
        (fmap roleOf recommendedOwner /= Just expected)
        "verdict.recommendedOwner.role"
        ("must be " <> ownerRoleText expected)
    unresolvedOwner =
      check
        (maybe True (\owner -> roleOf owner `notElem` [TriageOwner, JointOwners]) recommendedOwner)
        "verdict.recommendedOwner.role"
        "must be triage-owner or joint-owners for unresolved"
    materialClaimRequired =
      check
        (not (any (\PracticeReviewClaim {material, evidenceIds} -> material == Material && not (null evidenceIds)) claims))
        "verdict.claims"
        "suspect classifications require a cited material claim"
    noExceptionApproval =
      check (exceptionApproval /= NoApproval) "verdict.exceptionApproval" "must be no-approval outside legitimate-exception"

ownerRoleText :: RecommendedOwnerRole -> Text
ownerRoleText TargetOwner = "target-owner"
ownerRoleText PracticeOwner = "practice-owner"
ownerRoleText TriageOwner = "triage-owner"
ownerRoleText JointOwners = "joint-owners"
ownerRoleText ExceptionApprover = "exception-approver"

reReviewErrors :: ReReviewCondition -> [ReviewContractError]
reReviewErrors ReReviewCondition {condition, watches} =
  blankErrors "verdict.reReviewCondition.condition" condition
    <> concatMap (uncurry repoRefErrors) (indexedFields "verdict.reReviewCondition.watches" watches)

resolutionErrors :: PracticeReviewResolution -> [ReviewContractError]
resolutionErrors
  PracticeReviewResolution
    { schemaVersion,
      idempotencyKey,
      reviewId,
      outcome,
      reason,
      resultingApplicability,
      supersedingReviewId
    } =
    schemaErrors "resolution" schemaVersion
      <> blankErrors "resolution.idempotencyKey" (resolutionKeyText idempotencyKey)
      <> blankErrors "resolution.reason" reason
      <> resolutionOutcomeErrors outcome resultingApplicability supersedingReviewId reviewId

resolutionOutcomeErrors :: ResolutionOutcome -> Maybe Applicability -> Maybe ReviewId -> ReviewId -> [ReviewContractError]
resolutionOutcomeErrors outcome resultingApplicability supersedingReviewId reviewId =
  case outcome of
    Accepted ->
      requiredApplicability
        <> noSupersedingReview
    Rejected ->
      check (isJust resultingApplicability) "resolution.resultingApplicability" "must be absent for rejected"
        <> noSupersedingReview
    Narrowed ->
      requiredApplicability
        <> noSupersedingReview
    Superseded ->
      check (isJust resultingApplicability) "resolution.resultingApplicability" "must be absent for superseded"
        <> check (isNothing supersedingReviewId) "resolution.supersedingReviewId" "is required for superseded"
        <> check (supersedingReviewId == Just reviewId) "resolution.supersedingReviewId" "must name a different review"
  where
    requiredApplicability =
      case resultingApplicability of
        Nothing -> [contractError "resolution.resultingApplicability" "is required for this outcome"]
        Just applicability -> applicabilityErrors True "resolution.resultingApplicability" applicability
    noSupersedingReview =
      check (isJust supersedingReviewId) "resolution.supersedingReviewId" "must be absent for this outcome"

indexedFields :: Text -> [value] -> [(Text, value)]
indexedFields prefix = zipWith (\fieldIndex value -> (prefix <> "[" <> Text.pack (show fieldIndex) <> "]", value)) [(0 :: Int) ..]

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues = Set.toList . snd . foldl step (Set.empty, Set.empty)
  where
    step (seen, duplicates) value
      | Set.member value seen = (seen, Set.insert value duplicates)
      | otherwise = (Set.insert value seen, duplicates)

normalizeRepositoryId :: RepositoryId -> RepositoryId
normalizeRepositoryId (RepositoryId repository) = RepositoryId (Text.strip repository)

normalizeRepoRef :: RepoRef -> RepoRef
normalizeRepoRef RepoRef {repository, revision} =
  RepoRef {repository = normalizeRepositoryId repository, revision}

normalizeProject :: ProjectRef -> ProjectRef
normalizeProject ProjectRef {name, repository} =
  ProjectRef {name = Text.strip name, repository = normalizeRepositoryId repository}

normalizeApplicability :: Applicability -> Applicability
normalizeApplicability Applicability {projects, paths, dependencies, practices} =
  Applicability
    { projects = fmap normalizeProject projects,
      paths,
      dependencies = fmap (\(DependencyName name) -> DependencyName (Text.strip name)) dependencies,
      practices = fmap normalizePracticeKey practices
    }

normalizePracticeKey :: PracticeKey -> PracticeKey
normalizePracticeKey (PracticeKey practice) = PracticeKey (normalizeNamedKey practice)

normalizeOwnerPrincipal :: OwnerPrincipal -> OwnerPrincipal
normalizeOwnerPrincipal (OwnerPrincipal principal) = OwnerPrincipal (Text.strip principal)

normalizeReviewId :: ReviewId -> ReviewId
normalizeReviewId = id

normalizeResolutionId :: ResolutionId -> ResolutionId
normalizeResolutionId = id

normalizeEvidenceId :: EvidenceId -> EvidenceId
normalizeEvidenceId (EvidenceId evidence) = EvidenceId (Text.strip evidence)

normalizeClaimId :: ClaimId -> ClaimId
normalizeClaimId (ClaimId claim) = ClaimId (Text.strip claim)

normalizeRevisionRange :: RevisionRange -> RevisionRange
normalizeRevisionRange RevisionRange {changeKind, before, head = headRevision} =
  RevisionRange {changeKind, before, head = headRevision}

normalizeOwners :: ReviewOwners -> ReviewOwners
normalizeOwners ReviewOwners {targetOwner, practiceOwner, triageOwner, exceptionApprover} =
  ReviewOwners
    { targetOwner = normalizeOwnerPrincipal targetOwner,
      practiceOwner = normalizeOwnerPrincipal practiceOwner,
      triageOwner = normalizeOwnerPrincipal triageOwner,
      exceptionApprover = fmap normalizeOwnerPrincipal exceptionApprover
    }

normalizeRegisteredReference :: RegisteredPracticeReference -> RegisteredPracticeReference
normalizeRegisteredReference RegisteredPracticeReference {project, provenance, documentIds} =
  RegisteredPracticeReference
    { project = normalizeProject project,
      provenance = normalizeRepoRef provenance,
      documentIds = fmap (\(DocumentId name) -> DocumentId (Text.strip name)) documentIds
    }

normalizeUpstreamProject :: RegisteredUpstreamProject -> RegisteredUpstreamProject
normalizeUpstreamProject RegisteredUpstreamProject {project, dependency} =
  RegisteredUpstreamProject {project = normalizeProject project, dependency = case dependency of DependencyName name -> DependencyName (Text.strip name)}

normalizeAdoption :: PracticeAdoptionBinding -> PracticeAdoptionBinding
normalizeAdoption PracticeAdoptionBinding {practice, references, claimedApplicability, mode, owners, upstreamProjects} =
  PracticeAdoptionBinding
    { practice = normalizePracticeKey practice,
      references = fmap normalizeRegisteredReference references,
      claimedApplicability = normalizeApplicability claimedApplicability,
      mode,
      owners = normalizeOwners owners,
      upstreamProjects = fmap normalizeUpstreamProject upstreamProjects
    }

normalizeChangedReference :: ChangedReference -> ChangedReference
normalizeChangedReference ChangedReference {project, range, changedPaths} =
  ChangedReference {project = normalizeProject project, range = normalizeRevisionRange range, changedPaths}

normalizeTrigger :: PracticeReviewTrigger -> PracticeReviewTrigger
normalizeTrigger PracticeReviewTrigger {schemaVersion, triggerKind, idempotencyKey, target, targetRange, changedDecisionPaths, adoptions, referenceChange, priorReviewId} =
  PracticeReviewTrigger
    { schemaVersion,
      triggerKind,
      idempotencyKey = normalizeTriggerKey idempotencyKey,
      target = normalizeProject target,
      targetRange = normalizeRevisionRange targetRange,
      changedDecisionPaths,
      adoptions = fmap normalizeAdoption adoptions,
      referenceChange = fmap normalizeChangedReference referenceChange,
      priorReviewId = fmap normalizeReviewId priorReviewId
    }

normalizeContentReference :: ContentReference -> ContentReference
normalizeContentReference ContentReference {project, provenance, path, contentHash = ContentHash contentHash} =
  ContentReference
    { project = normalizeProject project,
      provenance = normalizeRepoRef provenance,
      path,
      contentHash = ContentHash (Text.strip contentHash)
    }

normalizeEvidenceItem :: EvidenceItem -> EvidenceItem
normalizeEvidenceItem EvidenceItem {evidenceId, role, content} =
  EvidenceItem {evidenceId = normalizeEvidenceId evidenceId, role, content = normalizeContentReference content}

normalizeClaim :: PracticeReviewClaim -> PracticeReviewClaim
normalizeClaim PracticeReviewClaim {claimId, kind, statement, material, evidenceIds} =
  PracticeReviewClaim
    { claimId = normalizeClaimId claimId,
      kind,
      statement,
      material,
      evidenceIds = fmap normalizeEvidenceId evidenceIds
    }

normalizeLineage :: ReviewLineage -> ReviewLineage
normalizeLineage ReviewLineage {parentSessionId, childSessionId, parentWorkflowId, childWorkflowId, priorReviewId} =
  ReviewLineage
    { parentSessionId,
      childSessionId,
      parentWorkflowId = WorkflowId (Text.strip parentWorkflowId.unWorkflowId),
      childWorkflowId = WorkflowId (Text.strip childWorkflowId.unWorkflowId),
      priorReviewId = fmap normalizeReviewId priorReviewId
    }

normalizeRecommendedOwner :: RecommendedOwner -> RecommendedOwner
normalizeRecommendedOwner RecommendedOwner {role, principals} =
  RecommendedOwner {role, principals = fmap normalizeOwnerPrincipal principals}

normalizeReReviewCondition :: ReReviewCondition -> ReReviewCondition
normalizeReReviewCondition ReReviewCondition {condition, watches} =
  ReReviewCondition {condition, watches = fmap normalizeRepoRef watches}

normalizeVerdict :: PracticeReviewVerdict -> PracticeReviewVerdict
normalizeVerdict PracticeReviewVerdict {schemaVersion, reviewId, triggerIdempotencyKey, practice, specialist, lineage, targetEvidence, referenceEvidence, upstreamEvidence, claims, confidence, routingRationale, classification, recommendedOwner, recommendedAction, exceptionApproval, reReviewCondition, applicability} =
  PracticeReviewVerdict
    { schemaVersion,
      reviewId = normalizeReviewId reviewId,
      triggerIdempotencyKey = normalizeTriggerKey triggerIdempotencyKey,
      practice = normalizePracticeKey practice,
      specialist = normalizeSpecialist specialist,
      lineage = normalizeLineage lineage,
      targetEvidence = fmap normalizeEvidenceItem targetEvidence,
      referenceEvidence = fmap normalizeEvidenceItem referenceEvidence,
      upstreamEvidence = fmap normalizeEvidenceItem upstreamEvidence,
      claims = fmap normalizeClaim claims,
      confidence,
      routingRationale,
      classification,
      recommendedOwner = fmap normalizeRecommendedOwner recommendedOwner,
      recommendedAction,
      exceptionApproval,
      reReviewCondition = normalizeReReviewCondition reReviewCondition,
      applicability = normalizeApplicability applicability
    }

normalizeResolution :: PracticeReviewResolution -> PracticeReviewResolution
normalizeResolution PracticeReviewResolution {schemaVersion, resolutionId, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId} =
  PracticeReviewResolution
    { schemaVersion,
      resolutionId = normalizeResolutionId resolutionId,
      idempotencyKey = normalizeResolutionKey idempotencyKey,
      reviewId = normalizeReviewId reviewId,
      outcome,
      resolver = normalizeOwnerPrincipal resolver,
      reason,
      resolvedAt,
      resultingApplicability = fmap normalizeApplicability resultingApplicability,
      supersedingReviewId = fmap normalizeReviewId supersedingReviewId
    }

practiceReviewAesonOptions :: Options
practiceReviewAesonOptions = defaultOptions {omitNothingFields = True}

practiceReviewEnumAesonOptions :: Options
practiceReviewEnumAesonOptions =
  defaultOptions
    { constructorTagModifier = camelTo2 '-',
      allNullaryToStringTag = True,
      tagSingleConstructors = True
    }

parsePracticeKey :: Text -> Either Text PracticeKey
parsePracticeKey = checkedReviewText "practice key" PracticeKey

practiceKeyText :: PracticeKey -> Text
practiceKeyText (PracticeKey value) = value

instance FromJSON PracticeKey where
  parseJSON = withText "practice key" (either (fail . Text.unpack) pure . parsePracticeKey)

parseOwnerPrincipal :: Text -> Either Text OwnerPrincipal
parseOwnerPrincipal = checkedReviewText "owner principal" OwnerPrincipal

ownerPrincipalText :: OwnerPrincipal -> Text
ownerPrincipalText (OwnerPrincipal value) = value

instance FromJSON OwnerPrincipal where
  parseJSON = withText "owner principal" (either (fail . Text.unpack) pure . parseOwnerPrincipal)

parseEvidenceId :: Text -> Either Text EvidenceId
parseEvidenceId = checkedReviewText "evidence label" EvidenceId

evidenceIdText :: EvidenceId -> Text
evidenceIdText (EvidenceId value) = value

instance FromJSON EvidenceId where
  parseJSON = withText "evidence label" (either (fail . Text.unpack) pure . parseEvidenceId)

parseClaimId :: Text -> Either Text ClaimId
parseClaimId = checkedReviewText "claim label" ClaimId

claimIdText :: ClaimId -> Text
claimIdText (ClaimId value) = value

instance FromJSON ClaimId where
  parseJSON = withText "claim label" (either (fail . Text.unpack) pure . parseClaimId)

parseContentHash :: Text -> Either Text ContentHash
parseContentHash = checkedReviewText "content hash" ContentHash

contentHashText :: ContentHash -> Text
contentHashText (ContentHash value) = value

instance FromJSON ContentHash where
  parseJSON = withText "content hash" (either (fail . Text.unpack) pure . parseContentHash)

checkedReviewText :: Text -> (Text -> value) -> Text -> Either Text value
checkedReviewText label constructor raw
  | Text.null (Text.strip raw) = Left (label <> " must not be blank")
  | otherwise = Right (constructor raw)

parseConfidence :: Integer -> Either Text Confidence
parseConfidence number
  | number >= 0 && number <= 100 = Right (Confidence (fromInteger number))
  | otherwise = Left "confidence must be between 0 and 100"

confidencePercent :: Confidence -> Int
confidencePercent (Confidence number) = number

zeroConfidence :: Confidence
zeroConfidence = Confidence 0

instance FromJSON Confidence where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseConfidence

-- | A local citation label for a bounded diagnostic claim, not an entity id.
evidenceProblemClaimId :: Int -> ClaimId
evidenceProblemClaimId ordinal = ClaimId ("evidence-problem-" <> Text.justifyRight 3 '0' (Text.pack (show ordinal)))

-- | Commit separate opaque source coordinates with explicit purpose/version.
-- This identifies a citation, not an allocated review or resolution entity.
sourceEvidenceIdV2 :: EvidenceRole -> RepoRef -> RelativePath -> ContentHash -> EvidenceId
sourceEvidenceIdV2 role RepoRef {repository = RepositoryId repository, revision} path (ContentHash hash) =
  EvidenceId
    ( "evidence-v2:"
        <> uuidText
          [ "source-evidence",
            "2",
            roleToken,
            repository,
            revisionText revision,
            relativePathText path,
            hash
          ]
    )
  where
    roleToken = case role of
      TargetEvidence -> "target"
      ReferenceEvidence -> "reference"
      UpstreamEvidence -> "upstream"

newtype DependencyName = DependencyName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseDependencyName :: Text -> Either Text DependencyName
parseDependencyName = checkedReviewText "dependency name" DependencyName

dependencyNameText :: DependencyName -> Text
dependencyNameText (DependencyName value) = value

instance FromJSON DependencyName where
  parseJSON = withText "dependency name" (either (fail . Text.unpack) pure . parseDependencyName)

newtype DocumentId = DocumentId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseDocumentId :: Text -> Either Text DocumentId
parseDocumentId = checkedReviewText "document locator" DocumentId

documentIdText :: DocumentId -> Text
documentIdText (DocumentId value) = value

instance FromJSON DocumentId where
  parseJSON = withText "document locator" (either (fail . Text.unpack) pure . parseDocumentId)

newtype TriggerKey = TriggerKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseTriggerKey :: Text -> Either Text TriggerKey
parseTriggerKey = checkedReviewText "trigger producer key" TriggerKey

triggerKeyText :: TriggerKey -> Text
triggerKeyText (TriggerKey value) = value

instance FromJSON TriggerKey where
  parseJSON = withText "trigger producer key" (either (fail . Text.unpack) pure . parseTriggerKey)

newtype ResolutionKey = ResolutionKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseResolutionKey :: Text -> Either Text ResolutionKey
parseResolutionKey = checkedReviewText "resolution producer key" ResolutionKey

resolutionKeyText :: ResolutionKey -> Text
resolutionKeyText (ResolutionKey value) = value

instance FromJSON ResolutionKey where
  parseJSON = withText "resolution producer key" (either (fail . Text.unpack) pure . parseResolutionKey)

normalizeTriggerKey :: TriggerKey -> TriggerKey
normalizeTriggerKey (TriggerKey value) = TriggerKey (normalizeOpaqueKey value)

normalizeResolutionKey :: ResolutionKey -> ResolutionKey
normalizeResolutionKey (ResolutionKey value) = ResolutionKey (normalizeOpaqueKey value)

normalizeSpecialist :: AgentName -> AgentName
normalizeSpecialist value = either (const value) id (mkAgentName (normalizeNamedKey (agentNameText value)))

data Materiality = Contextual | Material
  deriving stock (Eq, Show)

instance ToJSON Materiality where
  toJSON value = toJSON (value == Material)
  toEncoding value = toEncoding (value == Material)

instance FromJSON Materiality where
  parseJSON value = (\material -> if material then Material else Contextual) <$> parseJSON @Bool value
