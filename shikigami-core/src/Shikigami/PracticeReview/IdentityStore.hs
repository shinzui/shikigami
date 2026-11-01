{-# LANGUAGE MultilineStrings #-}

-- | Owner receipts for logical review requests. A parsed identity or journal
-- reference is a claim; the stored binding and current creator are rechecked.
module Shikigami.PracticeReview.IdentityStore
  ( ReviewIdentityRef,
    allocatedReviewId,
    reserveReviewIdentity,
    verifyReviewIdentity,
    reserveResolutionIdentity,
  )
where

import Contravariant.Extras (contrazip3, contrazip5)
import Data.Aeson (Value, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity, resolvedIdentity, resolvedIdentityText)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.PracticeReview
import Shikigami.PracticeReview.Identity (newResolutionId, newReviewId)
import Shikigami.Prelude hiding ((.=))

-- Positional and private: exported accessors cannot be used for record updates.
data ReviewIdentityRef = ReviewIdentityRef !ReviewId !ValidatedPracticeReviewTrigger !PracticeKey !AgentName
  deriving stock (Eq, Show)

allocatedReviewId :: ReviewIdentityRef -> ReviewId
allocatedReviewId (ReviewIdentityRef identifier _ _ _) = identifier

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

reviewCoordinates :: ResolvedAgentIdentity -> ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> (Text, Text, Text, Value)
reviewCoordinates identity validated practice specialist =
  let trigger@PracticeReviewTrigger {idempotencyKey, target = ProjectRef {repository}} = validatedTriggerValue validated
      binding = Aeson.object ["creator" .= resolvedIdentity identity, "trigger" .= trigger, "practice" .= practice, "specialist" .= specialist]
      key = versionedDigest "shikigami.practice-review-request/2" (Aeson.object ["targetRepository" .= repository, "key" .= idempotencyKey, "practice" .= practice, "specialist" .= specialist])
   in ("review", resolvedIdentityText identity, key, binding)

reserveReviewIdentity :: AppEnv -> ResolvedAgentIdentity -> ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> IO (Either Text ReviewIdentityRef)
reserveReviewIdentity app identity trigger practice specialist
  | not (validReviewRequest trigger practice normalized) = pure (Left "invalid allocated review request")
  | otherwise = reserveValidReviewIdentity app identity trigger practice normalized
  where
    normalized = normalizeSpecialist specialist

reserveValidReviewIdentity :: AppEnv -> ResolvedAgentIdentity -> ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> IO (Either Text ReviewIdentityRef)
reserveValidReviewIdentity app identity trigger practice specialist = do
  candidate <- newReviewId
  let (kind, owner, key, binding) = reviewCoordinates identity trigger practice specialist
  result <- runAppIO app (runTransaction (reserve kind owner key binding (reviewIdText candidate))) >>= storeResult
  pure $ do
    raw <- result
    identifier <- parseReviewId raw
    pure (ReviewIdentityRef identifier trigger practice specialist)

verifyReviewIdentity :: AppEnv -> ResolvedAgentIdentity -> ReviewIdentityRef -> ValidatedPracticeReviewVerdict -> IO (Either Text ())
verifyReviewIdentity app identity (ReviewIdentityRef identifier trigger practice specialist) validated = do
  let (kind, owner, key, binding) = reviewCoordinates identity trigger practice specialist
      PracticeReviewTrigger {idempotencyKey, target} = validatedTriggerValue trigger
      PracticeReviewVerdict {reviewId, triggerIdempotencyKey, practice = actualPractice, specialist = actualSpecialist, targetEvidence} = validatedVerdictValue validated
      metadataMatches = reviewId == identifier && triggerIdempotencyKey == idempotencyKey && actualPractice == practice && actualSpecialist == specialist
      targetsMatch = all (\EvidenceItem {content = ContentReference {project}} -> project == target) targetEvidence
  if not (metadataMatches && targetsMatch)
    then pure (Left "review does not match its allocated request")
    else do
      result <- runAppIO app (runTransaction (Tx.statement (kind, owner, key) selectReceipt)) >>= storeResult
      pure $ case result of
        Just (stored, storedBinding) | stored == reviewIdText identifier && storedBinding == binding -> Right ()
        _ -> Left "review identity receipt is absent or conflicts"

reserveResolutionIdentity :: AppEnv -> ResolvedAgentIdentity -> ValidatedResolutionRequest -> IO (Either Text ValidatedPracticeReviewResolution)
reserveResolutionIdentity app identity request = do
  candidate <- newResolutionId
  let raw@PracticeReviewResolutionRequest {reviewId, idempotencyKey} = validatedResolutionRequestValue request
  result <-
    runAppIO
      app
      ( runTransaction do
          owner <- Tx.statement (reviewIdText reviewId) selectReviewOwner
          if owner /= Just (resolvedIdentityText identity)
            then pure (Left "resolution does not belong to this review owner")
            else reserve "resolution" (reviewIdText reviewId) (resolutionKeyText idempotencyKey) (toJSON raw) (resolutionIdText candidate)
      )
      >>= storeResult
  pure $ do
    rawId <- result
    identifier <- parseResolutionId rawId
    pure (allocateResolution identifier request)

reserve :: Text -> Text -> Text -> Value -> Text -> Tx.Transaction (Either Text Text)
reserve kind owner key binding candidate = do
  Tx.statement (kind, owner, key, candidate, binding) insertReceipt
  Tx.statement (kind, owner, key) selectReceipt >>= \case
    Just (stored, storedBinding) | storedBinding == binding -> pure (Right stored)
    _ -> pure (Left "identity request conflicts with its retained receipt")

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

insertReceipt :: Statement (Text, Text, Text, Text, Value) ()
insertReceipt =
  preparable
    """
    INSERT INTO shikigami.practice_review_identities (kind, owner_key, request_key, entity_id, binding)
    VALUES ($1, $2, $3, $4, $5) ON CONFLICT (kind, owner_key, request_key) DO NOTHING
    """
    (contrazip5 textParam textParam textParam textParam (E.param (E.nonNullable E.jsonb)))
    D.noResult

selectReceipt :: Statement (Text, Text, Text) (Maybe (Text, Value))
selectReceipt =
  preparable
    """
    SELECT entity_id, binding FROM shikigami.practice_review_identities
    WHERE kind = $1 AND owner_key = $2 AND request_key = $3
    """
    (contrazip3 textParam textParam textParam)
    (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

selectReviewOwner :: Statement Text (Maybe Text)
selectReviewOwner =
  preparable
    "SELECT owner_key FROM shikigami.practice_review_identities WHERE kind = 'review' AND entity_id = $1"
    textParam
    (D.rowMaybe (D.column (D.nonNullable D.text)))

-- Transport failure must remain retryable and must never become a journaled refusal.
storeResult :: Either error a -> IO a
storeResult = either (const (ioError (userError "practice-review identity store unavailable"))) pure

validReviewRequest :: ValidatedPracticeReviewTrigger -> PracticeKey -> AgentName -> Bool
validReviewRequest validated practice specialist =
  let PracticeReviewTrigger {adoptions} = validatedTriggerValue validated
   in not (Text.null (Text.strip (agentNameText specialist))) && any (\PracticeAdoptionBinding {practice = registered} -> registered == practice) adoptions

-- This is the review contract's existing named-key normalization, not an agent
-- principal or compatibility-scope derivation.
normalizeSpecialist :: AgentName -> AgentName
normalizeSpecialist value = either (const value) id (mkAgentName (Text.toCaseFold (Text.strip (agentNameText value))))
