-- | Registered specialist orchestration for OpenTelemetry architecture review.
module Shikigami.Flow.OpenTelemetryPracticeReview
  ( opentelemetryPracticeReviewFlowName,
    opentelemetryPracticeReviewMermaid,
    opentelemetryPracticeReviewFlow,
  )
where

import Control.Exception (Exception, throw)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (find, sortOn)
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Kioku.Id (MemoryId, idText)
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Flow.Capability (Sink, emitSignal)
import Shikigami.PracticeReview
  ( ClaimId (..),
    ClaimKind (Inference),
    Confidence (..),
    ContentReference (..),
    EvidenceItem (..),
    ExceptionApproval (..),
    PracticeAdoptionBinding (..),
    PracticeKey (..),
    PracticeReviewClaim (..),
    PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ReReviewCondition (..),
    RecommendedOwner (..),
    RecommendedOwnerRole (..),
    RegisteredUpstreamProject (..),
    ReviewId (..),
    ReviewLineage (..),
    ReviewOwners (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    deriveReviewId,
    validateTrigger,
    validateVerdict,
    validatedResolutionValue,
    validatedTriggerValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Authorization
  ( AuthorizedPracticeReviewResolution,
    validateAuthorizedPracticeReviewResolution,
  )
import Shikigami.PracticeReview.Capability
  ( ExecutionContext,
    PracticeReviewAttention,
    PracticeReviewEvaluator,
    PracticeReviewEvidence,
    PracticeReviewExecutionContext (..),
    acquirePracticeReviewEvidence,
    evaluatePracticeReview,
    executionContext,
    requestPracticeReviewAttention,
  )
import Shikigami.PracticeReview.Evidence
  ( EvidenceBundle (..),
    EvidenceCompleteness (..),
    EvidenceProblem,
    EvidenceSource (..),
  )
import Shikigami.PracticeReview.Memory
  ( AdjudicatedPracticeReview (..),
    PracticeReviewChain (..),
    PracticeReviewChainEntry (..),
    PracticeReviewMemory,
    PracticeReviewMemoryEnvelope (..),
    RecalledPracticeReviews (..),
    ReviewRecallContext (..),
    provisionalMemoryId,
    recallPracticeReviewChain,
    recallPracticeReviews,
    rememberProvisional,
    resolveReview,
  )
import Shikigami.Prelude
import Shikigami.Repository (RepositoryId (..))
import Shikigami.Sink.Types (SinkOutcome (Enqueued), SinkResult (..))

opentelemetryPracticeReviewFlowName :: Text
opentelemetryPracticeReviewFlowName = "opentelemetry-practice-review"

opentelemetryPracticeReviewMermaid :: Text
opentelemetryPracticeReviewMermaid =
  Text.unlines
    [ "flowchart LR",
      "  Input --> Dispatch{trigger or resolution}",
      "  Dispatch --> Evidence",
      "  Evidence --> Recall",
      "  Recall --> Verdict",
      "  Dispatch --> Resolution",
      "  Verdict --> Memory",
      "  Resolution --> Memory",
      "  Memory --> History",
      "  History --> Attention"
    ]

opentelemetryPracticeReviewFlow ::
  ( ExecutionContext :> es,
    PracticeReviewEvidence :> es,
    PracticeReviewEvaluator :> es,
    PracticeReviewMemory :> es,
    PracticeReviewAttention :> es,
    Sink :> es
  ) =>
  Value ->
  Eff es Value
opentelemetryPracticeReviewFlow payload =
  case decodeInput payload of
    Left detail -> failFlow detail
    Right (ReviewTrigger trigger) -> reviewTrigger trigger
    Right (AuthorizedResolution envelope) -> resolveAuthorized envelope

data ReviewInput
  = ReviewTrigger !ValidatedPracticeReviewTrigger
  | AuthorizedResolution !AuthorizedPracticeReviewResolution

newtype PracticeReviewFlowFailure = PracticeReviewFlowFailure Text
  deriving stock (Eq, Show)

instance Exception PracticeReviewFlowFailure

decodeInput :: Value -> Either Text ReviewInput
decodeInput payload =
  case (strictDecode triggerInputKeys payload, strictDecode resolutionInputKeys payload) of
    (Aeson.Success rawTrigger, Aeson.Error _) ->
      ReviewTrigger <$> firstProblem "invalid practice-review trigger" (validateTrigger rawTrigger)
    (Aeson.Error _, Aeson.Success envelope) ->
      AuthorizedResolution envelope <$ firstProblem "invalid authorized resolution" (validateAuthorizedPracticeReviewResolution envelope)
    (Aeson.Success (_ :: PracticeReviewTrigger), Aeson.Success (_ :: AuthorizedPracticeReviewResolution)) ->
      Left "practice-review input ambiguously decodes as both a trigger and an authorized resolution"
    (Aeson.Error triggerProblem, Aeson.Error resolutionProblem) ->
      Left
        ( "practice-review input is neither a valid trigger nor an authorized resolution: trigger="
            <> Text.pack triggerProblem
            <> "; resolution="
            <> Text.pack resolutionProblem
        )

strictDecode :: (FromJSON value) => Set.Set Key.Key -> Value -> Aeson.Result value
strictDecode allowed payload@(Aeson.Object objectValue) =
  case Set.toAscList (Set.fromList (KeyMap.keys objectValue) `Set.difference` allowed) of
    [] -> Aeson.fromJSON payload
    extras -> Aeson.Error ("unknown top-level fields: " <> show (Key.toText <$> extras))
strictDecode _ payload = Aeson.fromJSON payload

triggerInputKeys :: Set.Set Key.Key
triggerInputKeys =
  Set.fromList
    [ "schemaVersion",
      "triggerKind",
      "idempotencyKey",
      "target",
      "targetRange",
      "changedDecisionPaths",
      "adoptions",
      "referenceChange",
      "priorReviewId"
    ]

resolutionInputKeys :: Set.Set Key.Key
resolutionInputKeys = Set.fromList ["schemaVersion", "resolution", "authorization"]

reviewTrigger ::
  ( ExecutionContext :> es,
    PracticeReviewEvidence :> es,
    PracticeReviewEvaluator :> es,
    PracticeReviewMemory :> es,
    PracticeReviewAttention :> es,
    Sink :> es
  ) =>
  ValidatedPracticeReviewTrigger ->
  Eff es Value
reviewTrigger validatedTrigger = do
  context <- executionContext
  lineage <- either failFlow pure (reviewLineage context trigger)
  adoption <- either failFlow pure (selectOpenTelemetryAdoption trigger)
  let recallContext = reviewRecallContext trigger adoption
  recalled <- recallPracticeReviews recallContext
  evidence <- acquirePracticeReviewEvidence validatedTrigger adoption (recalledResolutions recalled)
  validatedVerdict <-
    case completeness evidence of
      Complete -> do
        rawProposal <- evaluatePracticeReview evidence recalled
        rawVerdict <- case Aeson.fromJSON rawProposal of
          Aeson.Error detail -> failFlow ("practice-review evaluator returned invalid verdict JSON: " <> Text.pack detail)
          Aeson.Success verdict -> pure verdict
        either failFlow pure (trustedVerdict trigger adoption lineage evidence rawVerdict)
      Incomplete ->
        either failFlow pure (incompleteVerdict trigger adoption lineage evidence)
  remembered <- rememberProvisional (priorActiveMemoryId trigger recalled) validatedVerdict
  memoryId <- either (failFlow . ("practice-review provisional memory failed: " <>) . Text.pack . show) pure remembered
  let verdict = validatedVerdictValue validatedVerdict
  history <- emitSignal "review-history" reviewHistorySink (reviewHistoryPayload verdict)
  attention <- case (history, actionable verdict) of
    (SinkResult {outcome = Enqueued _}, True) -> Just <$> requestPracticeReviewAttention validatedVerdict
    _ -> pure Nothing
  pure
    ( Aeson.object
        [ "kind" Aeson..= ("practice-review" :: Text),
          "verdict" Aeson..= validatedVerdictValue validatedVerdict,
          "memoryId" Aeson..= idText memoryId,
          "history" Aeson..= history,
          "attention" Aeson..= attention
        ]
    )
  where
    trigger = validatedTriggerValue validatedTrigger

resolveAuthorized ::
  (PracticeReviewMemory :> es, Sink :> es) =>
  AuthorizedPracticeReviewResolution ->
  Eff es Value
resolveAuthorized envelope = do
  (validatedResolution, _) <-
    either
      (failFlow . ("authorized resolution was refused: " <>) . Text.pack . show)
      pure
      (validateAuthorizedPracticeReviewResolution envelope)
  let resolution@PracticeReviewResolution {reviewId} = validatedResolutionValue validatedResolution
      provisionalId = provisionalMemoryId reviewId
  chain <- recallPracticeReviewChain reviewId
  verdict <- maybe (failFlow "authorized resolution does not reference an existing provisional review") pure (provisionalReview reviewId chain)
  resolved <- resolveReview provisionalId validatedResolution
  memoryId <- either (failFlow . ("practice-review resolution memory failed: " <>) . Text.pack . show) pure resolved
  history <- emitSignal "resolution-history" resolutionHistorySink (resolutionHistoryPayload verdict resolution)
  pure
    ( Aeson.object
        [ "kind" Aeson..= ("practice-review-resolution" :: Text),
          "resolution" Aeson..= resolution,
          "memoryId" Aeson..= idText memoryId,
          "history" Aeson..= history
        ]
    )

reviewLineage :: PracticeReviewExecutionContext -> PracticeReviewTrigger -> Either Text ReviewLineage
reviewLineage PracticeReviewExecutionContext {parentWorkflowId, parentSessionId, childWorkflowId, childSessionId} PracticeReviewTrigger {priorReviewId} =
  case (parentWorkflowId, parentSessionId) of
    (Just recordedParentWorkflowId, Just recordedParentSessionId) ->
      Right
        ReviewLineage
          { parentSessionId = recordedParentSessionId,
            childSessionId,
            parentWorkflowId = recordedParentWorkflowId,
            childWorkflowId,
            priorReviewId
          }
    _ -> Left "practice-review trigger requires recorded parent workflow and session lineage"

selectOpenTelemetryAdoption :: PracticeReviewTrigger -> Either Text PracticeAdoptionBinding
selectOpenTelemetryAdoption PracticeReviewTrigger {adoptions} =
  case filter isOpenTelemetry adoptions of
    [adoption] -> Right adoption
    [] -> Left "practice-review trigger has no opentelemetry adoption"
    _ -> Left "practice-review trigger has more than one opentelemetry adoption"
  where
    isOpenTelemetry PracticeAdoptionBinding {practice = PracticeKey practice} =
      Text.toCaseFold (Text.strip practice) == "opentelemetry"

reviewRecallContext :: PracticeReviewTrigger -> PracticeAdoptionBinding -> ReviewRecallContext
reviewRecallContext PracticeReviewTrigger {target, changedDecisionPaths} PracticeAdoptionBinding {practice, upstreamProjects} =
  ReviewRecallContext
    { project = target,
      path = listToMaybe changedDecisionPaths,
      dependencies = Set.fromList [dependency | RegisteredUpstreamProject {dependency} <- upstreamProjects],
      practice
    }

recalledResolutions :: RecalledPracticeReviews -> [ValidatedPracticeReviewResolution]
recalledResolutions RecalledPracticeReviews {guiding, doNotRepeat, retired} =
  [resolution | AdjudicatedPracticeReview {resolution} <- guiding <> doNotRepeat <> retired]

trustedVerdict ::
  PracticeReviewTrigger ->
  PracticeAdoptionBinding ->
  ReviewLineage ->
  EvidenceBundle ->
  PracticeReviewVerdict ->
  Either Text ValidatedPracticeReviewVerdict
trustedVerdict
  trigger@PracticeReviewTrigger {idempotencyKey = triggerKey}
  adoption@PracticeAdoptionBinding {practice = adoptionPractice}
  lineage
  evidence@EvidenceBundle {target = evidenceTarget, references = evidenceReferences, upstream = evidenceUpstream}
  proposal@PracticeReviewVerdict {classification = proposalClassification, exceptionApproval = proposalApproval, reReviewCondition = proposalReReview} =
    firstProblem "invalid practice-review evaluator verdict" $
      validateVerdict
        proposal
          { schemaVersion = 1,
            reviewId = deriveReviewId trigger adoptionPractice opentelemetrySpecialist,
            triggerIdempotencyKey = triggerKey,
            practice = adoptionPractice,
            specialist = opentelemetrySpecialist,
            lineage,
            targetEvidence = citations evidenceTarget,
            referenceEvidence = citations evidenceReferences,
            upstreamEvidence = citations evidenceUpstream,
            recommendedOwner = trustedOwner adoption proposalClassification proposalApproval,
            reReviewCondition =
              proposalReReview
                { watches = [provenance | EvidenceItem {content = ContentReference {provenance}} <- allCitations evidence]
                }
          }

incompleteVerdict ::
  PracticeReviewTrigger ->
  PracticeAdoptionBinding ->
  ReviewLineage ->
  EvidenceBundle ->
  Either Text ValidatedPracticeReviewVerdict
incompleteVerdict
  trigger@PracticeReviewTrigger {idempotencyKey = triggerKey}
  PracticeAdoptionBinding {practice = adoptionPractice, owners = ReviewOwners {triageOwner}, claimedApplicability}
  lineage
  EvidenceBundle {target = evidenceTarget, references = evidenceReferences, upstream = evidenceUpstream, problems = evidenceProblems} =
    firstProblem "invalid deterministic unresolved verdict" $
      validateVerdict
        PracticeReviewVerdict
          { schemaVersion = 1,
            reviewId = deriveReviewId trigger adoptionPractice opentelemetrySpecialist,
            triggerIdempotencyKey = triggerKey,
            practice = adoptionPractice,
            specialist = opentelemetrySpecialist,
            lineage,
            targetEvidence = citations evidenceTarget,
            referenceEvidence = citations evidenceReferences,
            upstreamEvidence = citations evidenceUpstream,
            claims = problemClaims evidenceProblems,
            confidence = Confidence 0,
            routingRationale = "OpenTelemetry adoption selected by the recorded architecture-practice router delegation",
            classification = Unresolved,
            recommendedOwner = Just RecommendedOwner {role = TriageOwner, principals = [triageOwner]},
            recommendedAction = "Restore revision-pinned evidence access and re-run this advisory review",
            exceptionApproval = NoApproval,
            reReviewCondition = ReReviewCondition {condition = "Required revision-pinned evidence becomes available", watches = []},
            applicability = claimedApplicability
          }

trustedOwner :: PracticeAdoptionBinding -> PracticeReviewClassification -> ExceptionApproval -> Maybe RecommendedOwner
trustedOwner PracticeAdoptionBinding {owners = ReviewOwners {targetOwner, practiceOwner, triageOwner, exceptionApprover}} classification approval =
  case classification of
    Consistent -> Nothing
    TargetSuspect -> one TargetOwner targetOwner
    ReferenceSuspect -> one PracticeOwner practiceOwner
    Unresolved -> one TriageOwner triageOwner
    LegitimateException -> case approval of
      NoApproval -> Nothing
      ApprovalRequired -> exceptionApprover >>= one ExceptionApprover
  where
    one role principal = Just RecommendedOwner {role, principals = [principal]}

problemClaims :: [EvidenceProblem] -> [PracticeReviewClaim]
problemClaims problems =
  [ PracticeReviewClaim
      { claimId = ClaimId ("evidence-problem-" <> Text.justifyRight 3 '0' (Text.pack (show ordinal))),
        kind = Inference,
        statement = Text.take 512 (Text.pack (show problem)),
        material = True,
        evidenceIds = []
      }
  | (ordinal, problem) <- zip [(1 :: Int) ..] (sortOn show problems)
  ]

priorActiveMemoryId :: PracticeReviewTrigger -> RecalledPracticeReviews -> Maybe MemoryId
priorActiveMemoryId PracticeReviewTrigger {priorReviewId} _ = provisionalMemoryId <$> priorReviewId

provisionalReview :: ReviewId -> PracticeReviewChain -> Maybe PracticeReviewVerdict
provisionalReview wanted PracticeReviewChain {entries} =
  validatedVerdictValue <$> (find matches entries >>= extract)
  where
    matches PracticeReviewChainEntry {envelope = Just (ProvisionalReview verdict)} =
      case validatedVerdictValue verdict of
        PracticeReviewVerdict {reviewId = rememberedReviewId} -> rememberedReviewId == wanted
    matches _ = False
    extract PracticeReviewChainEntry {envelope = Just (ProvisionalReview verdict)} = Just verdict
    extract _ = Nothing

citations :: [EvidenceSource] -> [EvidenceItem]
citations = fmap citation

allCitations :: EvidenceBundle -> [EvidenceItem]
allCitations EvidenceBundle {target, references, upstream} = citations (target <> references <> upstream)

reviewHistorySink :: Agent.Sink
reviewHistorySink = Agent.KawaDigest {Agent.subjectType = "practice-review", Agent.verb = "practice-review.completed"}

resolutionHistorySink :: Agent.Sink
resolutionHistorySink = Agent.KawaDigest {Agent.subjectType = "practice-review", Agent.verb = "practice-review.resolved"}

reviewHistoryPayload :: PracticeReviewVerdict -> Value
reviewHistoryPayload verdict@PracticeReviewVerdict {reviewId, targetEvidence, referenceEvidence, upstreamEvidence} =
  Aeson.object
    [ "subject_id" Aeson..= ("practice-review/" <> reviewIdText reviewId),
      "verdict" Aeson..= verdict,
      "context_refs" Aeson..= historyContextRefs reviewId (targetEvidence <> referenceEvidence <> upstreamEvidence)
    ]

resolutionHistoryPayload :: PracticeReviewVerdict -> PracticeReviewResolution -> Value
resolutionHistoryPayload PracticeReviewVerdict {targetEvidence, referenceEvidence, upstreamEvidence} resolution@PracticeReviewResolution {reviewId} =
  Aeson.object
    [ "subject_id" Aeson..= ("practice-review/" <> reviewIdText reviewId),
      "resolution" Aeson..= resolution,
      "context_refs" Aeson..= historyContextRefs reviewId (targetEvidence <> referenceEvidence <> upstreamEvidence)
    ]

historyContextRefs :: ReviewId -> [EvidenceItem] -> [Value]
historyContextRefs reviewId evidence =
  uniqueOn
    id
    ( [ Aeson.object ["scheme" Aeson..= ("mori://" :: Text), "ref" Aeson..= repositoryRef repository]
      | EvidenceItem {content = ContentReference {project = ProjectRef {repository}}} <- evidence
      ]
        <> [ Aeson.object ["scheme" Aeson..= ("activity://" :: Text), "ref" Aeson..= ("practice-review/" <> reviewIdText reviewId)]
           ]
    )

repositoryRef :: RepositoryId -> Text
repositoryRef (RepositoryId raw) = fromMaybe raw (Text.stripPrefix "mori://" raw)

reviewIdText :: ReviewId -> Text
reviewIdText (ReviewId value) = value

actionable :: PracticeReviewVerdict -> Bool
actionable PracticeReviewVerdict {classification, exceptionApproval} =
  classification `elem` [TargetSuspect, ReferenceSuspect, Unresolved]
    || (classification == LegitimateException && exceptionApproval == ApprovalRequired)

uniqueOn :: (Ord key) => (value -> key) -> [value] -> [value]
uniqueOn key = reverse . snd . foldl add (Set.empty, [])
  where
    add (seen, retained) value
      | Set.member (key value) seen = (seen, retained)
      | otherwise = (Set.insert (key value) seen, value : retained)

firstProblem :: (Show problem) => Text -> Either problem value -> Either Text value
firstProblem prefix = either (Left . ((prefix <> ": ") <>) . Text.pack . show) Right

failFlow :: Text -> Eff es value
failFlow detail = throw (PracticeReviewFlowFailure detail) `seq` pure (error "unreachable")

opentelemetrySpecialist :: Text
opentelemetrySpecialist = "opentelemetry-practice-reviewer"
