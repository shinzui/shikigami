{-# LANGUAGE TypeFamilies #-}

-- | Narrow replay-safe ports used by the architecture-practice review flow.
--
-- The flow body sees only these operations. Content-plane, provider and
-- delivery IO stay in the pack's interpreters
-- ("FlowPack.PracticeReview.Runtime"), and every externally derived result is
-- captured by one fixed Keiro step before the body can act on it.
module FlowPack.PracticeReview.Capability
  ( PracticeReviewExecutionContext (..),
    ExecutionContext (..),
    executionContext,
    PracticeReviewEvidence (..),
    acquirePracticeReviewEvidence,
    PracticeReviewEvaluator (..),
    evaluatePracticeReview,
    PracticeReviewAttention (..),
    requestPracticeReviewAttention,
    AttentionReservationResult (..),
    AttentionRecipientMap,
    AttentionRecipient,
    parseAttentionRecipient,
    attentionRecipientText,
    mkAttentionRecipientMap,
    parseAttentionRecipientMap,
    renderAttentionRecipientMap,
    emptyAttentionRecipientMap,
    lookupAttentionRecipient,
  )
where

import Control.Monad (foldM)
import Data.Aeson (Value, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import FlowPack.PracticeReview.Evidence (EvidenceBundle)
import FlowPack.PracticeReview.Identity (AttentionKey)
import FlowPack.PracticeReview.Memory (RecalledPracticeReviews)
import FlowPack.PracticeReview.Types
  ( OwnerPrincipal,
    PracticeAdoptionBinding,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    ownerPrincipalText,
  )
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Kioku.Id (SessionId)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Flow.Sdk (Dispatch (Dynamic), DispatchOf, Eff, Effect, SinkMessageId, send, (:>))
import Shikigami.Prelude hiding ((.=))

-- | Recorded execution metadata that is trusted independently of producer
-- payload JSON. A delegated review requires both parent values.
data PracticeReviewExecutionContext = PracticeReviewExecutionContext
  { identity :: !AgentIdentity,
    parentWorkflowId :: !(Maybe WorkflowId),
    parentSessionId :: !(Maybe SessionId),
    childWorkflowId :: !WorkflowId,
    childSessionId :: !SessionId
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PracticeReviewExecutionContext where
  toJSON context =
    Aeson.object
      [ "identity" .= context.identity,
        "parentWorkflowId" .= fmap (.unWorkflowId) context.parentWorkflowId,
        "parentSessionId" .= context.parentSessionId,
        "childWorkflowId" .= context.childWorkflowId.unWorkflowId,
        "childSessionId" .= context.childSessionId
      ]

instance FromJSON PracticeReviewExecutionContext where
  parseJSON = Aeson.withObject "PracticeReviewExecutionContext" \value ->
    PracticeReviewExecutionContext
      <$> value .: "identity"
      <*> (value .:? "parentWorkflowId" >>= traverse parseWorkflowId)
      <*> value .:? "parentSessionId"
      <*> (value .: "childWorkflowId" >>= parseWorkflowId)
      <*> value .: "childSessionId"
    where
      parseWorkflowId = either (fail . show) pure . mkWorkflowId

data ExecutionContext :: Effect where
  ReadExecutionContext :: ExecutionContext m PracticeReviewExecutionContext

type instance DispatchOf ExecutionContext = Dynamic

executionContext :: (ExecutionContext :> es) => Eff es PracticeReviewExecutionContext
executionContext = send ReadExecutionContext

data PracticeReviewEvidence :: Effect where
  AcquirePracticeReviewEvidence ::
    ValidatedPracticeReviewTrigger ->
    PracticeAdoptionBinding ->
    [ValidatedPracticeReviewResolution] ->
    PracticeReviewEvidence m EvidenceBundle

type instance DispatchOf PracticeReviewEvidence = Dynamic

acquirePracticeReviewEvidence ::
  (PracticeReviewEvidence :> es) =>
  ValidatedPracticeReviewTrigger ->
  PracticeAdoptionBinding ->
  [ValidatedPracticeReviewResolution] ->
  Eff es EvidenceBundle
acquirePracticeReviewEvidence trigger adoption prior =
  send (AcquirePracticeReviewEvidence trigger adoption prior)

data PracticeReviewEvaluator :: Effect where
  EvaluatePracticeReview :: EvidenceBundle -> RecalledPracticeReviews -> PracticeReviewEvaluator m Value

type instance DispatchOf PracticeReviewEvaluator = Dynamic

evaluatePracticeReview ::
  (PracticeReviewEvaluator :> es) =>
  EvidenceBundle ->
  RecalledPracticeReviews ->
  Eff es Value
evaluatePracticeReview evidence recalled = send (EvaluatePracticeReview evidence recalled)

data AttentionReservationResult
  = Reserved
      { attentionKey :: !AttentionKey,
        outboxMessageId :: !SinkMessageId
      }
  | Coalesced
      { attentionKey :: !AttentionKey,
        outboxMessageId :: !SinkMessageId
      }
  | AttentionSkipped !Value
  deriving stock (Eq, Show, Generic)

instance ToJSON AttentionReservationResult where toJSON = genericToJSON eventAesonOptions

instance FromJSON AttentionReservationResult where parseJSON = genericParseJSON eventAesonOptions

data PracticeReviewAttention :: Effect where
  RequestPracticeReviewAttention :: ValidatedPracticeReviewVerdict -> PracticeReviewAttention m AttentionReservationResult

type instance DispatchOf PracticeReviewAttention = Dynamic

requestPracticeReviewAttention ::
  (PracticeReviewAttention :> es) =>
  ValidatedPracticeReviewVerdict ->
  Eff es AttentionReservationResult
requestPracticeReviewAttention verdict = send (RequestPracticeReviewAttention verdict)

newtype AttentionRecipientMap = AttentionRecipientMap (Map AttentionOwnerSet AttentionRecipient)
  deriving stock (Eq, Show)

mkAttentionRecipientMap :: [(Text, Text)] -> Either Text AttentionRecipientMap
mkAttentionRecipientMap entries = AttentionRecipientMap <$> foldM add Map.empty entries
  where
    add current (rawOwnerKey, rawRecipient) = do
      ownerKey <- canonicalOwnerKey rawOwnerKey
      recipient <- parseAttentionRecipient rawRecipient
      unlessEither (Map.notMember ownerKey current) ("duplicate practice-review owner key: " <> ownerKeyText ownerKey)
      pure (Map.insert ownerKey recipient current)

-- | Parse the scalar configuration form @owner=recipient,owner+owner=recipient@.
-- Owner sets are canonicalized before duplicate detection.
parseAttentionRecipientMap :: Text -> Either Text AttentionRecipientMap
parseAttentionRecipientMap raw
  | Text.null (Text.strip raw) = Right emptyAttentionRecipientMap
  | otherwise = traverse parseEntry (Text.splitOn "," raw) >>= mkAttentionRecipientMap
  where
    parseEntry entry =
      case Text.splitOn "=" entry of
        [ownerKey, recipient] -> Right (ownerKey, recipient)
        _ -> Left ("invalid practice-review attention recipient entry: " <> Text.strip entry)

renderAttentionRecipientMap :: AttentionRecipientMap -> Text
renderAttentionRecipientMap (AttentionRecipientMap recipients) =
  Text.intercalate "," [ownerKeyText ownerKey <> "=" <> attentionRecipientText recipient | (ownerKey, recipient) <- Map.toAscList recipients]

emptyAttentionRecipientMap :: AttentionRecipientMap
emptyAttentionRecipientMap = AttentionRecipientMap Map.empty

lookupAttentionRecipient :: AttentionRecipientMap -> [OwnerPrincipal] -> Maybe AttentionRecipient
lookupAttentionRecipient (AttentionRecipientMap recipients) owners =
  Map.lookup (AttentionOwnerSet (sort (Text.strip . ownerPrincipalText <$> owners))) recipients

canonicalOwnerKey :: Text -> Either Text AttentionOwnerSet
canonicalOwnerKey raw = do
  let owners = sort (Text.strip <$> Text.splitOn "+" raw)
  unlessEither (not (null owners) && all (not . Text.null) owners) ("invalid practice-review owner key: " <> raw)
  pure (AttentionOwnerSet owners)

unlessEither :: Bool -> Text -> Either Text ()
unlessEither True _ = Right ()
unlessEither False problem = Left problem

-- Retain components, not a delimiter-joined lookup key: one owner containing
-- '+' must not match a configured set containing two different owners.
newtype AttentionOwnerSet = AttentionOwnerSet [Text]
  deriving stock (Eq, Ord, Show)

ownerKeyText :: AttentionOwnerSet -> Text
ownerKeyText (AttentionOwnerSet owners) = Text.intercalate "+" owners

newtype AttentionRecipient = AttentionRecipient Text
  deriving stock (Eq, Ord, Show)

parseAttentionRecipient :: Text -> Either Text AttentionRecipient
parseAttentionRecipient raw
  | "recipient_" `Text.isPrefixOf` value && Text.length value > Text.length ("recipient_" :: Text) = Right (AttentionRecipient value)
  | otherwise = Left ("invalid Kizashi practice-review recipient: " <> raw)
  where
    value = Text.strip raw

attentionRecipientText :: AttentionRecipient -> Text
attentionRecipientText (AttentionRecipient value) = value

instance ToJSON AttentionRecipient where
  toJSON = toJSON . attentionRecipientText
  toEncoding = toEncoding . attentionRecipientText

instance FromJSON AttentionRecipient where
  parseJSON = Aeson.withText "attention recipient" (either (fail . Text.unpack) pure . parseAttentionRecipient)
