{-# LANGUAGE TypeFamilies #-}

-- | Narrow replay-safe ports used by the architecture-practice review Flow.
--
-- The Flow sees only these operations. Content-plane, provider, and delivery
-- IO stay in the AgentRun interpreter, and every externally-derived result is
-- captured by one fixed Keiro step before the Flow can act on it.
module Shikigami.PracticeReview.Capability
  ( PracticeReviewExecutionContext (..),
    ExecutionContext,
    executionContext,
    runExecutionContext,
    PracticeReviewEvidence,
    acquirePracticeReviewEvidence,
    PracticeReviewEvaluator,
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
    PracticeReviewRuntime (..),
    unavailablePracticeReviewRuntime,
    unavailablePracticeReviewRuntimeWithRecipients,
    failClosedPracticeReviewRuntime,
    modelPracticeReviewEvaluator,
    runPracticeReviewEvidence,
    runPracticeReviewEvaluator,
    runPracticeReviewAttention,
  )
where

import Baikai.Context (systemUser)
import Baikai.Response (flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.ResponseFormat (ResponseFormat (JsonObject))
import Control.Exception qualified as Exception
import Control.Monad (foldM)
import Data.Aeson (Value, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Lazy qualified as LazyText
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (StepName (..), Workflow, step)
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Kioku.Id (SessionId)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Behavior.Compatibility
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest)
import Shikigami.PracticeReview
  ( OwnerPrincipal,
    PracticeAdoptionBinding,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    ownerPrincipalText,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Evidence
  ( DependencyPinResolver (..),
    EvidenceBundle,
    EvidenceReadError (ContentPlaneUnavailable),
    EvidenceReader (..),
    acquireEvidence,
    defaultEvidenceLimits,
  )
import Shikigami.PracticeReview.Identity (AttentionKey)
import Shikigami.PracticeReview.Memory
  ( AdjudicatedPracticeReview (..),
    RecalledPracticeReviews (..),
  )
import Shikigami.Prelude hiding ((.=))
import Shikigami.Sink.Delivery (SinkMessageId)

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

runExecutionContext :: PracticeReviewExecutionContext -> Eff (ExecutionContext : es) a -> Eff es a
runExecutionContext context = interpret \_ -> \case
  ReadExecutionContext -> pure context

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

-- | Process-local adapters. Their outputs cross the workflow journal before
-- the Flow sees them; the callbacks themselves never enter the effect row.
data PracticeReviewRuntime = PracticeReviewRuntime
  { evidenceReader :: !EvidenceReader,
    dependencyPinResolver :: !DependencyPinResolver,
    evaluator :: !(BehaviorEnv -> EvidenceBundle -> RecalledPracticeReviews -> IO (Either Text Value)),
    attention :: !(ValidatedPracticeReviewVerdict -> IO (Either Text AttentionReservationResult)),
    attentionRecipients :: !AttentionRecipientMap
  }
  deriving stock (Generic)

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

unavailablePracticeReviewRuntime :: PracticeReviewRuntime
unavailablePracticeReviewRuntime = unavailablePracticeReviewRuntimeWithRecipients emptyAttentionRecipientMap

unavailablePracticeReviewRuntimeWithRecipients :: AttentionRecipientMap -> PracticeReviewRuntime
unavailablePracticeReviewRuntimeWithRecipients recipients =
  PracticeReviewRuntime
    { evidenceReader = unavailableReader,
      dependencyPinResolver = DependencyPinResolver (\_ _ -> Left unavailableDetail),
      evaluator = \_ _ _ -> pure (Left "practice-review evaluator is unavailable"),
      attention = \_ -> pure (Left "practice-review attention is unavailable"),
      attentionRecipients = recipients
    }
  where
    unavailableDetail = "practice-review content plane is unavailable"
    unavailableReader =
      EvidenceReader
        { resolveRef = \_ _ -> unavailable,
          readBlob = \_ _ -> unavailable,
          readDiff = \_ _ _ _ -> unavailable,
          readTree = \_ _ _ -> unavailable,
          grep = \_ _ _ -> unavailable
        }
    unavailable :: IO (Either EvidenceReadError value)
    unavailable = pure (Left (ContentPlaneUnavailable unavailableDetail))

-- | Production composition while the Kikan content-plane gate remains closed.
-- Acquisition fails closed through the explicit unavailable reader, but a
-- complete replayed snapshot can still use the sanctioned model evaluator.
failClosedPracticeReviewRuntime :: AttentionRecipientMap -> PracticeReviewRuntime
failClosedPracticeReviewRuntime recipients =
  PracticeReviewRuntime
    { evidenceReader = unavailableReader,
      dependencyPinResolver = DependencyPinResolver (\_ _ -> Left unavailableDetail),
      evaluator = modelPracticeReviewEvaluator,
      attention = \_ -> pure (Left "legacy practice-review attention is unavailable"),
      attentionRecipients = recipients
    }
  where
    unavailableDetail = "practice-review content plane is unavailable"
    unavailableReader =
      EvidenceReader
        { resolveRef = \_ _ -> unavailable,
          readBlob = \_ _ -> unavailable,
          readDiff = \_ _ _ _ -> unavailable,
          readTree = \_ _ _ -> unavailable,
          grep = \_ _ _ -> unavailable
        }
    unavailable :: IO (Either EvidenceReadError value)
    unavailable = pure (Left (ContentPlaneUnavailable unavailableDetail))

-- | Ask the model selected by the already-resolved sanctioned profile for one
-- raw JSON proposal. The Flow replaces all trusted identity/evidence fields and
-- runs the strict domain validator before the proposal can affect state.
modelPracticeReviewEvaluator :: BehaviorEnv -> EvidenceBundle -> RecalledPracticeReviews -> IO (Either Text Value)
modelPracticeReviewEvaluator env@BehaviorEnv {model, options} evidence recalled = do
  let context = systemUser practiceReviewSystemPrompt (practiceReviewUserPrompt evidence recalled)
      structuredOptions = options & #responseFormat .~ Just JsonObject
  case validateResponseRequest model structuredOptions context of
    Left refusal -> pure (Left (renderResponseCompatibilityError refusal))
    Right () -> do
      response <- completeBehaviorRequest env model context structuredOptions
      case responseError response of
        Just failure -> pure (Left (boundedEvaluatorDetail (Text.pack (show failure))))
        Nothing ->
          let responseText = flattenAssistantText (flattenAssistantBlocks response)
           in pure
                ( first
                    (boundedEvaluatorDetail . ("practice-review evaluator returned invalid JSON: " <>) . Text.pack)
                    (Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 responseText))
                )

practiceReviewSystemPrompt :: Text
practiceReviewSystemPrompt =
  Text.unlines
    [ "You are an advisory OpenTelemetry architecture-practice reviewer. Return one JSON object and no prose.",
      "Classify the supplied bounded evidence as consistent, target-suspect, reference-suspect, legitimate-exception, or unresolved.",
      "Every material claim must cite supplied evidence ids. Never invent repository content or authority.",
      "Return the complete PracticeReviewVerdict JSON shape; execution-owned ids, lineage, evidence, ownership, and watches are replaced and validated by the caller."
    ]

practiceReviewUserPrompt :: EvidenceBundle -> RecalledPracticeReviews -> Text
practiceReviewUserPrompt evidence RecalledPracticeReviews {guiding, doNotRepeat, pending, retired, diagnostics} =
  LazyText.toStrict
    ( encodeToLazyText
        ( Aeson.object
            [ "evidence" .= evidence,
              "priorMemory"
                .= Aeson.object
                  [ "guiding" .= (adjudicatedValue <$> guiding),
                    "doNotRepeat" .= (adjudicatedValue <$> doNotRepeat),
                    "pending" .= (validatedVerdictValue <$> pending),
                    "retired" .= (adjudicatedValue <$> retired),
                    "diagnostics" .= diagnostics
                  ]
            ]
        )
    )
  where
    adjudicatedValue AdjudicatedPracticeReview {verdict, resolution} =
      Aeson.object
        [ "verdict" .= validatedVerdictValue verdict,
          "resolution" .= validatedResolutionValue resolution
        ]

boundedEvaluatorDetail :: Text -> Text
boundedEvaluatorDetail = Text.take 512

runPracticeReviewEvidence ::
  (Workflow :> es, IOE :> es) =>
  Bool ->
  PracticeReviewRuntime ->
  Eff (PracticeReviewEvidence : es) a ->
  Eff es a
runPracticeReviewEvidence journal PracticeReviewRuntime {evidenceReader, dependencyPinResolver} =
  interpret \_ -> \case
    AcquirePracticeReviewEvidence trigger adoption prior ->
      journaled "practice-review-evidence" $
        acquireEvidence defaultEvidenceLimits evidenceReader dependencyPinResolver trigger adoption prior
  where
    journaled label operation
      | journal = step (StepName label) (liftIO operation)
      | otherwise = liftIO operation

runPracticeReviewEvaluator ::
  (Workflow :> es, IOE :> es) =>
  Bool ->
  BehaviorEnv ->
  PracticeReviewRuntime ->
  Eff (PracticeReviewEvaluator : es) a ->
  Eff es a
runPracticeReviewEvaluator journal behaviorEnv PracticeReviewRuntime {evaluator} =
  interpret \_ -> \case
    EvaluatePracticeReview evidence recalled ->
      journaled "practice-review-evaluate" do
        evaluator behaviorEnv evidence recalled >>= either (Exception.throwIO . userError . Text.unpack) pure
  where
    journaled label operation
      | journal = step (StepName label) (liftIO operation)
      | otherwise = liftIO operation

runPracticeReviewAttention ::
  (Workflow :> es, IOE :> es) =>
  Bool ->
  PracticeReviewRuntime ->
  Eff (PracticeReviewAttention : es) a ->
  Eff es a
runPracticeReviewAttention journal PracticeReviewRuntime {attention} =
  interpret \_ -> \case
    RequestPracticeReviewAttention verdict ->
      journaled "practice-review-attention" do
        attention verdict >>= either (Exception.throwIO . userError . Text.unpack) pure
  where
    journaled label operation
      | journal = step (StepName label) (liftIO operation)
      | otherwise = liftIO operation

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
