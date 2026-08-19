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

practiceReviewAesonOptions :: Options
practiceReviewAesonOptions = defaultOptions {omitNothingFields = True}

practiceReviewEnumAesonOptions :: Options
practiceReviewEnumAesonOptions =
  defaultOptions
    { constructorTagModifier = camelTo2 '-',
      allNullaryToStringTag = True,
      tagSingleConstructors = True
    }
