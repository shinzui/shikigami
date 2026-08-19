-- | Versioned, pure contracts for architecture-practice review.
--
-- This module deliberately contains no workflow, persistence, model-provider,
-- or sink behavior. 'Shikigami.Agent.RunJob.RunJob' carries the JSON payload;
-- the durable review flow will decode and validate it at its own boundary.
module Shikigami.PracticeReview
  ( practiceReviewSchemaVersion,
    ReviewId (..),
    PracticeKey (..),
    OwnerPrincipal (..),
    ProjectRef (..),
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
    ResolutionId (..),
    EvidenceId (..),
    ClaimId (..),
    ContentHash (..),
    Confidence (..),
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
  )
where

import Data.Aeson (Value (Object))
import Data.Aeson.KeyMap qualified as KeyMap
import Shikigami.Prelude
import Shikigami.Repository (RelativePath, RepoRef, RepositoryId, Revision)

-- | The only schema version accepted by the first contract release.
practiceReviewSchemaVersion :: Int
practiceReviewSchemaVersion = 1

-- | Stable identity shared by verdicts, memory, activities, and attention.
newtype ReviewId = ReviewId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Stable key for one registered architecture practice.
newtype PracticeKey = PracticeKey {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Resolved identity of a person or approved artifact workflow.
newtype OwnerPrincipal = OwnerPrincipal {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

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
    dependencies :: ![Text],
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
    documentIds :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RegisteredPracticeReference where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON RegisteredPracticeReference where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Registered upstream source whose compatible revision will be selected by
-- evidence acquisition from a target dependency pin.
data RegisteredUpstreamProject = RegisteredUpstreamProject
  { project :: !ProjectRef,
    dependency :: !Text
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
  { schemaVersion :: !Int,
    triggerKind :: !PracticeReviewTriggerKind,
    idempotencyKey :: !Text,
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

-- | Stable identity of one explicit human resolution command.
newtype ResolutionId = ResolutionId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Identity of one pinned evidence item within a verdict.
newtype EvidenceId = EvidenceId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Identity of one claim within a verdict.
newtype ClaimId = ClaimId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest supplied by the revision-pinned content plane.
newtype ContentHash = ContentHash {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Integer confidence percentage. Validation accepts values from 0 through
-- 100 inclusive.
newtype Confidence = Confidence {value :: Int}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

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
    material :: !Bool,
    evidenceIds :: ![EvidenceId]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewClaim where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON PracticeReviewClaim where parseJSON = genericParseJSON practiceReviewAesonOptions

-- | Parent router and child specialist execution lineage.
data ReviewLineage = ReviewLineage
  { parentSessionId :: !Text,
    childSessionId :: !Text,
    parentWorkflowId :: !Text,
    childWorkflowId :: !Text,
    priorReviewId :: !(Maybe ReviewId)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewLineage where toJSON = genericToJSON practiceReviewAesonOptions

instance FromJSON ReviewLineage where parseJSON = genericParseJSON practiceReviewAesonOptions

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
  { schemaVersion :: !Int,
    reviewId :: !ReviewId,
    triggerIdempotencyKey :: !Text,
    practice :: !PracticeKey,
    specialist :: !Text,
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
  { schemaVersion :: !Int,
    resolutionId :: !ResolutionId,
    idempotencyKey :: !Text,
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

practiceReviewAesonOptions :: Options
practiceReviewAesonOptions = defaultOptions {omitNothingFields = True}

practiceReviewEnumAesonOptions :: Options
practiceReviewEnumAesonOptions =
  defaultOptions
    { constructorTagModifier = camelTo2 '-',
      allNullaryToStringTag = True,
      tagSingleConstructors = True
    }
