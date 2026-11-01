-- | Registered specialist orchestration for OpenTelemetry architecture review.
module Shikigami.Flow.OpenTelemetryPracticeReview
  ( opentelemetryPracticeReviewFlowName,
    opentelemetryPracticeReviewMermaid,
    opentelemetryPracticeReviewFlow,
  )
where

import Control.Exception (Exception, throw)
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (MemoryId, idText)
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name qualified as AgentName
import Shikigami.Flow.Capability (Sink, emitSignal)
import Shikigami.PracticeReview
  ( ClaimKind (Inference),
    ContentReference (..),
    EvidenceItem (..),
    ExceptionApproval (..),
    Materiality (..),
    PracticeAdoptionBinding (..),
    PracticeReviewClaim (..),
    PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewResolutionRequest (..),
    PracticeReviewTrigger (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ReReviewCondition (..),
    RecommendedOwner (..),
    RecommendedOwnerRole (..),
    RegisteredUpstreamProject (..),
    ReviewId,
    ReviewLineage (..),
    ReviewOwners (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    ValidatedPracticeReviewVerdict,
    evidenceProblemClaimId,
    practiceKeyText,
    practiceReviewSchemaVersion,
    reviewIdText,
    validateTrigger,
    validateVerdict,
    validatedResolutionRequestValue,
    validatedResolutionValue,
    validatedTriggerValue,
    validatedVerdictValue,
    zeroConfidence,
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
    ResolvedPracticeReview (..),
    ReviewRecallContext (..),
    allocatedReviewId,
    provisionalMemoryId,
    recallPracticeReviewChain,
    recallPracticeReviews,
    rememberProvisional,
    reserveReviewIdentity,
    resolveReview,
  )
import Shikigami.Prelude hiding ((.=))
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
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
  reference <- reserveReviewIdentity validatedTrigger adoption.practice opentelemetrySpecialist >>= either (failFlow . Text.pack . show) pure
  let identifier = allocatedReviewId reference
      recallContext = reviewRecallContext trigger adoption
  recalled <- recallPracticeReviews recallContext
  evidence <- acquirePracticeReviewEvidence validatedTrigger adoption (recalledResolutions recalled)
  validatedVerdict <-
    case (.completeness) evidence of
      Complete -> do
        rawProposal <- evaluatePracticeReview evidence recalled
        rawVerdict <- case Aeson.fromJSON (case rawProposal of Aeson.Object proposal -> Aeson.Object (foldr (\(key, value) -> KeyMap.insert key value) proposal [("schemaVersion", toJSON practiceReviewSchemaVersion), ("reviewId", toJSON identifier), ("triggerIdempotencyKey", toJSON trigger.idempotencyKey), ("specialist", toJSON opentelemetrySpecialist), ("lineage", toJSON lineage)]); other -> other) of
          Aeson.Error detail -> failFlow ("practice-review evaluator returned invalid verdict JSON: " <> Text.pack detail)
          Aeson.Success verdict -> pure verdict
        either failFlow pure (trustedVerdict identifier trigger adoption lineage evidence rawVerdict)
      Incomplete ->
        either failFlow pure (incompleteVerdict identifier trigger adoption lineage evidence)
  remembered <- rememberProvisional reference (priorActiveMemoryId trigger recalled) validatedVerdict
  memoryId <- either (failFlow . ("practice-review provisional memory failed: " <>) . Text.pack . show) pure remembered
  let verdict = validatedVerdictValue validatedVerdict
  history <- emitSignal (declarationCoordinate "review-history") reviewHistorySink (reviewHistoryPayload verdict)
  attention <- case (history, actionable verdict) of
    (SinkResult {outcome = Enqueued _}, True) -> Just <$> requestPracticeReviewAttention validatedVerdict
    _ -> pure Nothing
  pure
    ( Aeson.object
        [ "kind" .= ("practice-review" :: Text),
          "verdict" .= validatedVerdictValue validatedVerdict,
          "memoryId" .= idText memoryId,
          "history" .= history,
          "attention" .= attention
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
  let PracticeReviewResolutionRequest {reviewId} = validatedResolutionRequestValue validatedResolution
      provisionalId = provisionalMemoryId reviewId
  chain <- recallPracticeReviewChain reviewId
  verdict <- maybe (failFlow "authorized resolution does not reference an existing provisional review") pure (provisionalReview reviewId chain)
  resolved <- resolveReview provisionalId validatedResolution
  ResolvedPracticeReview {memoryId, resolution = allocatedResolution} <- either (failFlow . ("practice-review resolution memory failed: " <>) . Text.pack . show) pure resolved
  let resolution = validatedResolutionValue allocatedResolution
  history <- emitSignal (declarationCoordinate "resolution-history") resolutionHistorySink (resolutionHistoryPayload verdict resolution)
  pure
    ( Aeson.object
        [ "kind" .= ("practice-review-resolution" :: Text),
          "resolution" .= resolution,
          "memoryId" .= idText memoryId,
          "history" .= history
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
    isOpenTelemetry PracticeAdoptionBinding {practice} =
      Text.toCaseFold (Text.strip (practiceKeyText practice)) == "opentelemetry"

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
  ReviewId ->
  PracticeReviewTrigger ->
  PracticeAdoptionBinding ->
  ReviewLineage ->
  EvidenceBundle ->
  PracticeReviewVerdict ->
  Either Text ValidatedPracticeReviewVerdict
trustedVerdict
  identifier
  PracticeReviewTrigger {idempotencyKey = triggerKey}
  adoption@PracticeAdoptionBinding {practice = adoptionPractice}
  lineage
  evidence@EvidenceBundle {target = evidenceTarget, references = evidenceReferences, upstream = evidenceUpstream}
  proposal@PracticeReviewVerdict {classification = proposalClassification, exceptionApproval = proposalApproval, reReviewCondition = proposalReReview} =
    firstProblem "invalid practice-review evaluator verdict" $
      validateVerdict
        (proposal & #schemaVersion .~ practiceReviewSchemaVersion & #reviewId .~ (identifier) & #triggerIdempotencyKey .~ (triggerKey) & #practice .~ (adoptionPractice) & #specialist .~ (opentelemetrySpecialist) & #lineage .~ (lineage) & #targetEvidence .~ (citations evidenceTarget) & #referenceEvidence .~ (citations evidenceReferences) & #upstreamEvidence .~ (citations evidenceUpstream) & #recommendedOwner .~ (trustedOwner adoption proposalClassification proposalApproval) & #reReviewCondition .~ ((proposalReReview & #watches .~ ([provenance | EvidenceItem {content = ContentReference {provenance}} <- allCitations evidence]))))

incompleteVerdict ::
  ReviewId ->
  PracticeReviewTrigger ->
  PracticeAdoptionBinding ->
  ReviewLineage ->
  EvidenceBundle ->
  Either Text ValidatedPracticeReviewVerdict
incompleteVerdict
  identifier
  PracticeReviewTrigger {idempotencyKey = triggerKey}
  PracticeAdoptionBinding {practice = adoptionPractice, owners = ReviewOwners {triageOwner}, claimedApplicability}
  lineage
  EvidenceBundle {target = evidenceTarget, references = evidenceReferences, upstream = evidenceUpstream, problems = evidenceProblems} =
    firstProblem "invalid deterministic unresolved verdict" $
      validateVerdict
        PracticeReviewVerdict
          { schemaVersion = practiceReviewSchemaVersion,
            reviewId = identifier,
            triggerIdempotencyKey = triggerKey,
            practice = adoptionPractice,
            specialist = opentelemetrySpecialist,
            lineage,
            targetEvidence = citations evidenceTarget,
            referenceEvidence = citations evidenceReferences,
            upstreamEvidence = citations evidenceUpstream,
            claims = problemClaims evidenceProblems,
            confidence = zeroConfidence,
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
      { claimId = evidenceProblemClaimId ordinal,
        kind = Inference,
        statement = Text.take 512 (Text.pack (show problem)),
        material = Material,
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
citations = fmap (.citation)

allCitations :: EvidenceBundle -> [EvidenceItem]
allCitations EvidenceBundle {target, references, upstream} = citations (target <> references <> upstream)

reviewHistorySink :: Agent.Sink
reviewHistorySink = Agent.KawaDigest {Agent.subjectType = Agent.activityCoordinate "practice-review", Agent.verb = Agent.activityCoordinate "practice-review.completed"}

resolutionHistorySink :: Agent.Sink
resolutionHistorySink = Agent.KawaDigest {Agent.subjectType = Agent.activityCoordinate "practice-review", Agent.verb = Agent.activityCoordinate "practice-review.resolved"}

reviewHistoryPayload :: PracticeReviewVerdict -> Value
reviewHistoryPayload verdict@PracticeReviewVerdict {reviewId, targetEvidence, referenceEvidence, upstreamEvidence} =
  Aeson.object
    [ "subject_id" .= ("practice-review/" <> reviewIdText reviewId),
      "verdict" .= verdict,
      "context_refs" .= historyContextRefs reviewId (targetEvidence <> referenceEvidence <> upstreamEvidence)
    ]

resolutionHistoryPayload :: PracticeReviewVerdict -> PracticeReviewResolution -> Value
resolutionHistoryPayload PracticeReviewVerdict {targetEvidence, referenceEvidence, upstreamEvidence} resolution@PracticeReviewResolution {reviewId} =
  Aeson.object
    [ "subject_id" .= ("practice-review/" <> reviewIdText reviewId),
      "resolution" .= resolution,
      "context_refs" .= historyContextRefs reviewId (targetEvidence <> referenceEvidence <> upstreamEvidence)
    ]

historyContextRefs :: ReviewId -> [EvidenceItem] -> [Value]
historyContextRefs reviewId evidence =
  uniqueOn
    id
    ( [ Aeson.object ["scheme" .= ("mori://" :: Text), "ref" .= repositoryRef repository]
      | EvidenceItem {content = ContentReference {project = ProjectRef {repository}}} <- evidence
      ]
        <> [ Aeson.object ["scheme" .= ("activity://" :: Text), "ref" .= ("practice-review/" <> reviewIdText reviewId)]
           ]
    )

repositoryRef :: RepositoryId -> Text
repositoryRef value = let raw = repositoryIdText value in fromMaybe raw (Text.stripPrefix "mori://" raw)

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

opentelemetrySpecialist :: AgentName.AgentName
opentelemetrySpecialist = AgentName.agentNameFromNonEmpty ('o' :| "pentelemetry-practice-reviewer")
