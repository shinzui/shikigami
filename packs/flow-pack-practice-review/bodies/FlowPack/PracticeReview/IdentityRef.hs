-- | The allocated identity of one logical review request, as a flow body and
-- the journal carry it. Holding one is a claim: the store rechecks the binding
-- and the current creator before a review is remembered against it.
--
-- The constructor is private. "FlowPack.PracticeReview.IdentityStore" mints a
-- reference with 'mkReviewIdentityRef' after the receipt is durable, and a
-- journal decodes one through 'FromJSON'; both run the same check, so neither
-- can state more than a well-formed claim.
module FlowPack.PracticeReview.IdentityRef
  ( ReviewIdentityRef,
    mkReviewIdentityRef,
    ReviewIdentityBinding (..),
    reviewIdentityBinding,
    allocatedReviewId,
    validReviewRequest,
    normalizeSpecialist,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import FlowPack.PracticeReview.Types
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Prelude hiding ((.=))

-- Positional and private: exported accessors cannot be used for record updates.
data ReviewIdentityRef = ReviewIdentityRef !ReviewId !ValidatedPracticeReviewTrigger !PracticeKey !AgentName
  deriving stock (Eq, Show)

allocatedReviewId :: ReviewIdentityRef -> ReviewId
allocatedReviewId (ReviewIdentityRef identifier _ _ _) = identifier

-- | A reference for an allocated id and the request it was allocated to. The
-- specialist is normalized, and a request the trigger does not register is
-- refused.
mkReviewIdentityRef :: ReviewId -> ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> Either Text ReviewIdentityRef
mkReviewIdentityRef identifier trigger practice specialist
  | validReviewRequest trigger practice normalized = Right (ReviewIdentityRef identifier trigger practice normalized)
  | otherwise = Left "invalid allocated review request"
  where
    normalized = normalizeSpecialist specialist

-- | The read view of a reference: what the store rechecks against its receipt.
data ReviewIdentityBinding = ReviewIdentityBinding
  { reviewId :: !ReviewId,
    trigger :: !ValidatedPracticeReviewTrigger,
    practice :: !PracticeKey,
    specialist :: !AgentName
  }

reviewIdentityBinding :: ReviewIdentityRef -> ReviewIdentityBinding
reviewIdentityBinding (ReviewIdentityRef reviewId trigger practice specialist) =
  ReviewIdentityBinding {reviewId, trigger, practice, specialist}

instance ToJSON ReviewIdentityRef where
  toJSON (ReviewIdentityRef identifier trigger practice specialist) =
    Aeson.object ["reviewId" .= identifier, "trigger" .= validatedTriggerValue trigger, "practice" .= practice, "specialist" .= specialist]

instance FromJSON ReviewIdentityRef where
  parseJSON = Aeson.withObject "ReviewIdentityRef" \value -> do
    identifier <- value .: "reviewId"
    trigger <- value .: "trigger" >>= either (fail . show) pure . validateTrigger
    practice <- value .: "practice"
    specialist <- value .: "specialist"
    unless (specialist == normalizeSpecialist specialist && validReviewRequest trigger practice specialist) (fail "invalid allocated review request")
    pure (ReviewIdentityRef identifier trigger practice specialist)

validReviewRequest :: ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> Bool
validReviewRequest validated practice specialist =
  let PracticeReviewTrigger {adoptions} = validatedTriggerValue validated
   in not (Text.null (Text.strip (agentNameText specialist))) && any (\PracticeAdoptionBinding {practice = registered} -> registered == practice) adoptions

-- This is the review contract's existing named-key normalization, not an agent
-- principal or compatibility-scope derivation.
normalizeSpecialist :: AgentName -> AgentName
normalizeSpecialist value = either (const value) id (mkAgentName (Text.toCaseFold (Text.strip (agentNameText value))))
