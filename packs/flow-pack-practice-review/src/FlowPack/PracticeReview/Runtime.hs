-- | The pack's process-local adapters and the interpreters that put their
-- results in the journal.
--
-- A 'PracticeReviewRuntime' is closed over when the pack value is built
-- ("FlowPack.PracticeReview"). Its outputs cross a fixed @practice-review-*@
-- step before the flow body sees them; the callbacks themselves never enter
-- the effect row.
module FlowPack.PracticeReview.Runtime
  ( PracticeReviewRuntime (..),
    AttentionRecipients (..),
    unavailablePracticeReviewRuntime,
    unavailablePracticeReviewRuntimeWithRecipients,
    failClosedPracticeReviewRuntime,
    modelPracticeReviewEvaluator,
    runExecutionContext,
    runPracticeReviewEvidence,
    runPracticeReviewEvaluator,
    runPracticeReviewAttention,
  )
where

import Control.Exception qualified as Exception
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Lazy qualified as LazyText
import FlowPack.PracticeReview.Capability
import FlowPack.PracticeReview.Evidence
  ( DependencyPinResolver (..),
    EvidenceBundle,
    EvidenceReadError (ContentPlaneUnavailable),
    EvidenceReader (..),
    acquireEvidence,
    defaultEvidenceLimits,
  )
import FlowPack.PracticeReview.Memory
  ( AdjudicatedPracticeReview (..),
    RecalledPracticeReviews (..),
  )
import FlowPack.PracticeReview.Types
  ( ValidatedPracticeReviewVerdict,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Shikigami.Flow.Sdk (Eff, StepName (..), Workflow, step, (:>))
import Shikigami.Pack.Sdk (IOE, RunModel (..), interpret, liftIO)
import Shikigami.Prelude (Generic, Text)

-- | Process-local adapters. Their outputs cross the workflow journal before
-- the Flow sees them; the callbacks themselves never enter the effect row.
data PracticeReviewRuntime = PracticeReviewRuntime
  { evidenceReader :: !EvidenceReader,
    dependencyPinResolver :: !DependencyPinResolver,
    -- | Given the run's model, propose a verdict for complete evidence.
    evaluator :: !(RunModel -> EvidenceBundle -> RecalledPracticeReviews -> IO (Either Text Value)),
    attention :: !(ValidatedPracticeReviewVerdict -> IO (Either Text AttentionReservationResult)),
    attentionRecipients :: !AttentionRecipients
  }
  deriving stock (Generic)

-- | Where the map from review owners to Kizashi recipients comes from.
data AttentionRecipients
  = -- | The composed executable's @practice_review.attention_recipients@
    -- setting. This is the production source.
    RecipientsFromSettings
  | -- | A map fixed when the runtime was built, for a test.
    FixedRecipients !AttentionRecipientMap

runExecutionContext :: PracticeReviewExecutionContext -> Eff (ExecutionContext : es) a -> Eff es a
runExecutionContext context = interpret \_ -> \case
  ReadExecutionContext -> pure context

unavailablePracticeReviewRuntime :: PracticeReviewRuntime
unavailablePracticeReviewRuntime = unavailablePracticeReviewRuntimeWithRecipients emptyAttentionRecipientMap

unavailablePracticeReviewRuntimeWithRecipients :: AttentionRecipientMap -> PracticeReviewRuntime
unavailablePracticeReviewRuntimeWithRecipients recipients =
  PracticeReviewRuntime
    { evidenceReader = unavailableReader,
      dependencyPinResolver = DependencyPinResolver (\_ _ -> Left unavailableDetail),
      evaluator = \_ _ _ -> pure (Left "practice-review evaluator is unavailable"),
      attention = \_ -> pure (Left "practice-review attention is unavailable"),
      attentionRecipients = FixedRecipients recipients
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
failClosedPracticeReviewRuntime :: PracticeReviewRuntime
failClosedPracticeReviewRuntime =
  PracticeReviewRuntime
    { evidenceReader = unavailableReader,
      dependencyPinResolver = DependencyPinResolver (\_ _ -> Left unavailableDetail),
      evaluator = modelPracticeReviewEvaluator,
      attention = \_ -> pure (Left "legacy practice-review attention is unavailable"),
      attentionRecipients = RecipientsFromSettings
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

-- | Ask the run's model, already narrowed by its sanctioned profile, for one
-- raw JSON proposal. The flow replaces all trusted identity and evidence
-- fields and runs the strict domain validator before the proposal can affect
-- state.
modelPracticeReviewEvaluator :: RunModel -> EvidenceBundle -> RecalledPracticeReviews -> IO (Either Text Value)
modelPracticeReviewEvaluator model evidence recalled =
  model.completeJsonObject practiceReviewSystemPrompt (practiceReviewUserPrompt evidence recalled) >>= \case
    Left failure -> pure (Left (boundedEvaluatorDetail failure))
    Right responseText ->
      pure
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
  RunModel ->
  PracticeReviewRuntime ->
  Eff (PracticeReviewEvaluator : es) a ->
  Eff es a
runPracticeReviewEvaluator journal model PracticeReviewRuntime {evaluator} =
  interpret \_ -> \case
    EvaluatePracticeReview evidence recalled ->
      journaled "practice-review-evaluate" do
        evaluator model evidence recalled >>= either (Exception.throwIO . userError . Text.unpack) pure
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
