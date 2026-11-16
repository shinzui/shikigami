-- | The interpreter of "FlowPack.PracticeReview.Memory": review persistence
-- through Kioku's record and retire protocol, each operation journaled under
-- one fixed @practice-review-*@ label.
--
-- A review transition owns logical ids, typed envelopes and an exact practice
-- scope. Every durable call journals its operation; the explicit unjournaled
-- interpreter is test-only.
module FlowPack.PracticeReview.Memory.Store
  ( PracticeReviewMemoryEnv (..),
    practiceReviewScope,
    runPracticeReviewMemory,
    runPracticeReviewMemoryUnjournaled,
  )
where

import Data.List (sortOn)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import FlowPack.PracticeReview.IdentityStore qualified as IdentityStore
import FlowPack.PracticeReview.Memory
import FlowPack.PracticeReview.Types
  ( PracticeKey,
    PracticeReviewResolution (..),
    PracticeReviewResolutionRequest (..),
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
    ReviewId,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewVerdict,
    ValidatedResolutionRequest,
    confidencePercent,
    practiceKeyText,
    reviewIdText,
    validatedResolutionRequestValue,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Kioku.Api.Scope (MemoryScope (..), ScopeKind (..))
import Kioku.Api.Types qualified as Kioku
import Kioku.Id (MemoryId, SessionId, idText, parseId)
import Kioku.Memory (MemoryWriteError (..))
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..), SupersedeMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Principal (ResolvedAgentIdentity)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Flow.Sdk (Eff, StepName (..), Workflow, step, (:>))
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (shikigamiNamespace)
import Shikigami.Pack.Sdk (IOE, interpret, liftIO)
import Shikigami.Prelude (Text)

practiceReviewScope :: PracticeKey -> MemoryScope
practiceReviewScope practice =
  ScopeEntity shikigamiNamespace (ScopeKind "practice-review") (normalizeToken (practiceKeyText practice))

-- | What the interpreter needs of one run. The pack builds it from the
-- kernel's 'Shikigami.Pack.Sdk.FlowRunContext'.
data PracticeReviewMemoryEnv = PracticeReviewMemoryEnv
  { appEnv :: !AppEnv,
    agent :: !AgentDecl,
    identity :: !ResolvedAgentIdentity,
    sessionId :: !(Maybe SessionId)
  }

-- | Interpret review persistence through fixed, declarable Keiro steps.
runPracticeReviewMemory :: (Workflow :> es, IOE :> es) => PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemory = runPracticeReviewMemoryWithJournal True

-- | Test interpreter for exercising several operations without fixed journal
-- labels. Durable runtime code always uses 'runPracticeReviewMemory'.
runPracticeReviewMemoryUnjournaled :: (Workflow :> es, IOE :> es) => PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemoryUnjournaled = runPracticeReviewMemoryWithJournal False

runPracticeReviewMemoryWithJournal :: (Workflow :> es, IOE :> es) => Bool -> PracticeReviewMemoryEnv -> Eff (PracticeReviewMemory : es) a -> Eff es a
runPracticeReviewMemoryWithJournal journalReviewMemory env action =
  interpret
    ( \_ -> \case
        ReserveReviewIdentity trigger practice specialist ->
          runOperation journalReviewMemory "practice-review-reserve-identity" (fmap (either (Left . ReviewMemoryRefused) Right) (IdentityStore.reserveReviewIdentity env.appEnv env.identity trigger practice specialist))
        RememberProvisional reference prior verdict ->
          runOperation journalReviewMemory "practice-review-remember-provisional" (rememberProvisionalIO env reference prior verdict)
        ResolveReview provisional resolution ->
          runOperation journalReviewMemory "practice-review-resolve" (resolveReviewIO env provisional resolution)
        RecallPracticeReviews context ->
          runOperation journalReviewMemory "practice-review-recall" (recallPracticeReviewsIO env context)
        RecallPracticeReviewChain review ->
          runOperation journalReviewMemory "practice-review-chain" (recallPracticeReviewChainIO env review)
    )
    action
  where
    runOperation journal label operation
      | journal = step (StepName label) (liftIO operation)
      | otherwise = liftIO operation

rememberProvisionalIO :: PracticeReviewMemoryEnv -> ReviewIdentityRef -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> IO (Either ReviewMemoryError MemoryId)
rememberProvisionalIO env reference prior validatedVerdict =
  IdentityStore.verifyReviewIdentity env.appEnv env.identity reference validatedVerdict >>= \case
    Left problem -> pure (Left (ReviewMemoryRefused problem))
    Right () -> rememberAllocatedProvisionalIO env prior validatedVerdict

rememberAllocatedProvisionalIO :: PracticeReviewMemoryEnv -> Maybe MemoryId -> ValidatedPracticeReviewVerdict -> IO (Either ReviewMemoryError MemoryId)
rememberAllocatedProvisionalIO env prior validatedVerdict = do
  let PracticeReviewVerdict {reviewId, practice} = validatedVerdictValue validatedVerdict
      candidate = provisionalMemoryId reviewId
      envelope = ProvisionalReview validatedVerdict
  recordCandidate env candidate practice (verdictConfidence validatedVerdict) Kioku.MemoryPattern prior envelope >>= \case
    Left err -> pure (Left err)
    Right _ -> finishTransition env prior candidate

resolveReviewIO :: PracticeReviewMemoryEnv -> MemoryId -> ValidatedResolutionRequest -> IO (Either ReviewMemoryError ResolvedPracticeReview)
resolveReviewIO env suppliedProvisional request = do
  let PracticeReviewResolutionRequest {reviewId} = validatedResolutionRequestValue request
  if suppliedProvisional /= provisionalMemoryId reviewId
    then pure (Left (ReviewProvisionalIdMismatch (provisionalMemoryId reviewId) suppliedProvisional))
    else
      loadEnvelope env suppliedProvisional >>= \case
        Left problem -> pure (Left problem)
        Right (ResolvedReview _ _) -> pure (Left (ReviewExpectedProvisional (idText suppliedProvisional)))
        Right (ProvisionalReview _) ->
          IdentityStore.reserveResolutionIdentity env.appEnv env.identity request >>= \case
            Left problem -> pure (Left (ReviewMemoryRefused problem))
            Right resolution -> fmap (fmap (\memoryId -> ResolvedPracticeReview {memoryId, resolution})) (resolveAllocatedReviewIO env suppliedProvisional resolution)

resolveAllocatedReviewIO :: PracticeReviewMemoryEnv -> MemoryId -> ValidatedPracticeReviewResolution -> IO (Either ReviewMemoryError MemoryId)
resolveAllocatedReviewIO env suppliedProvisional validatedResolution = do
  let PracticeReviewResolution {reviewId = resolutionReviewId, resolutionId, outcome} = validatedResolutionValue validatedResolution
      expectedProvisional = provisionalMemoryId resolutionReviewId
  if suppliedProvisional /= expectedProvisional
    then pure (Left (ReviewProvisionalIdMismatch expectedProvisional suppliedProvisional))
    else
      loadEnvelope env suppliedProvisional >>= \case
        Left err -> pure (Left err)
        Right (ResolvedReview _ _) -> pure (Left (ReviewExpectedProvisional (idText suppliedProvisional)))
        Right (ProvisionalReview verdict) -> do
          let PracticeReviewVerdict {reviewId = verdictReviewId, practice} = validatedVerdictValue verdict
          if verdictReviewId /= resolutionReviewId
            then pure (Left (ReviewIdMismatch verdictReviewId resolutionReviewId))
            else do
              let candidate = resolvedMemoryId resolutionId
                  envelope = ResolvedReview verdict validatedResolution
                  memoryType = resolutionMemoryType outcome
              recordCandidate env candidate practice Kioku.HighConfidence memoryType (Just suppliedProvisional) envelope >>= \case
                Left err -> pure (Left err)
                Right _ -> finishTransition env (Just suppliedProvisional) candidate

finishTransition :: PracticeReviewMemoryEnv -> Maybe MemoryId -> MemoryId -> IO (Either ReviewMemoryError MemoryId)
finishTransition _ Nothing candidate = pure (Right candidate)
finishTransition env (Just prior) candidate =
  retireMemory env prior candidate >>= \case
    Right _ -> pure (Right candidate)
    Left (ResolutionConflict winner) ->
      retireMemory env candidate winner >>= \case
        Right _ -> pure (Left (ResolutionConflict winner))
        Left err -> pure (Left err)
    Left err -> pure (Left err)

recordCandidate :: PracticeReviewMemoryEnv -> MemoryId -> PracticeKey -> Kioku.Confidence -> Kioku.MemoryType -> Maybe MemoryId -> PracticeReviewMemoryEnvelope -> IO (Either ReviewMemoryError MemoryId)
recordCandidate PracticeReviewMemoryEnv {appEnv, agent = AgentDecl {name = agentName}, identity, sessionId} candidate practice confidence memoryType supersedes envelope = do
  recordedAt <- getCurrentTime
  let command =
        RecordMemoryData
          { memoryId = candidate,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor identity,
            ownerPrincipal = Nothing,
            agentId = agentNameText agentName,
            sessionId,
            scope = practiceReviewScope practice,
            memoryType,
            content = encodePracticeReviewMemory envelope,
            priority = 100,
            confidence,
            tags = practiceReviewTags envelope,
            supersedes,
            recordedAt
          }
  runAppIO appEnv (Memory.recordWithContext (shikigamiWriteContext identity) command) >>= \case
    Left storeError -> ioError (userError ("failed to record practice-review memory: " <> show storeError))
    Right (Right stored) -> pure (Right stored)
    Right (Left (MemoryConflict detail)) -> pure (Left (ReviewContentConflict candidate detail))
    Right (Left err) -> pure (Left (ReviewMemoryRefused (Text.pack (show err))))

retireMemory :: PracticeReviewMemoryEnv -> MemoryId -> MemoryId -> IO (Either ReviewMemoryError MemoryId)
retireMemory PracticeReviewMemoryEnv {appEnv, identity} loser winner = do
  supersededAt <- getCurrentTime
  let command =
        SupersedeMemoryData
          { memoryId = loser,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor identity,
            supersededBy = winner,
            supersededAt
          }
  runAppIO appEnv (Memory.supersedeWithContext (shikigamiWriteContext identity) command) >>= \case
    Left storeError -> ioError (userError ("failed to supersede practice-review memory: " <> show storeError))
    Right (Right stored) -> pure (Right stored)
    Right (Left err) ->
      lookupRecordedWinner appEnv loser >>= \case
        Left readError -> pure (Left readError)
        Right (Just recordedWinner) -> pure (Left (ResolutionConflict recordedWinner))
        Right Nothing -> pure (Left (ReviewMemoryRefused (Text.pack (show err))))

lookupRecordedWinner :: AppEnv -> MemoryId -> IO (Either ReviewMemoryError (Maybe MemoryId))
lookupRecordedWinner appEnv loser =
  readMemoryRow appEnv loser >>= \case
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (ReviewMemoryNotFound (idText loser)))
    Right (Just MemoryRow {supersededBy = Nothing}) -> pure (Right Nothing)
    Right (Just MemoryRow {supersededBy = Just winnerText}) ->
      case parseId winnerText of
        Left err -> pure (Left (ReviewMemoryMalformed (idText loser) err))
        Right winner -> pure (Right (Just winner))

loadEnvelope :: PracticeReviewMemoryEnv -> MemoryId -> IO (Either ReviewMemoryError PracticeReviewMemoryEnvelope)
loadEnvelope PracticeReviewMemoryEnv {appEnv} memoryId =
  fmap
    ( \case
        Left err -> Left err
        Right Nothing -> Left (ReviewMemoryNotFound (idText memoryId))
        Right (Just MemoryRow {content}) ->
          firstReviewError (idText memoryId) (decodePracticeReviewMemory content)
    )
    (readMemoryRow appEnv memoryId)

readMemoryRow :: AppEnv -> MemoryId -> IO (Either ReviewMemoryError (Maybe MemoryRow))
readMemoryRow appEnv memoryId =
  runAppIO appEnv (Memory.getMemoryRowById shikigamiMemorySpace memoryId) >>= \case
    Left storeError -> ioError (userError ("failed to read practice-review memory: " <> show storeError))
    Right (Left readError) -> pure (Left (ReviewMemoryRefused (Text.pack (show readError))))
    Right (Right row) -> pure (Right row)

firstReviewError :: Text -> Either Text value -> Either ReviewMemoryError value
firstReviewError memoryId = either (Left . ReviewMemoryMalformed memoryId) Right

verdictConfidence :: ValidatedPracticeReviewVerdict -> Kioku.Confidence
verdictConfidence validated =
  let PracticeReviewVerdict {confidence} = validatedVerdictValue validated
      percentage = confidencePercent confidence
   in if percentage >= 80
        then Kioku.HighConfidence
        else
          if percentage >= 50
            then Kioku.MediumConfidence
            else Kioku.LowConfidence

resolutionMemoryType :: ResolutionOutcome -> Kioku.MemoryType
resolutionMemoryType = \case
  Accepted -> Kioku.MemoryConstraint
  Narrowed -> Kioku.MemoryConstraint
  Rejected -> Kioku.MemoryFact
  Superseded -> Kioku.MemoryFact

recallPracticeReviewsIO :: PracticeReviewMemoryEnv -> ReviewRecallContext -> IO RecalledPracticeReviews
recallPracticeReviewsIO PracticeReviewMemoryEnv {appEnv} context@ReviewRecallContext {practice} =
  runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (practiceReviewScope practice)) >>= \case
    Left storeError -> ioError (userError ("failed to recall practice-review memories: " <> show storeError))
    Right (Left readError) -> ioError (userError ("failed to recall practice-review memories: " <> show readError))
    Right (Right rows) -> pure (classifyActiveRows context rows)

classifyActiveRows :: ReviewRecallContext -> [MemoryRow] -> RecalledPracticeReviews
classifyActiveRows context rows =
  RecalledPracticeReviews
    { guiding = fmap snd (sortOn fst guidingWithKeys),
      doNotRepeat = fmap snd (sortOn fst rejectedWithKeys),
      pending = fmap snd (sortOn fst pendingWithKeys),
      retired = fmap snd (sortOn fst retiredWithKeys),
      diagnostics = sortOn diagnosticKey malformed
    }
  where
    classified = classifyRow context <$> rows
    guidingWithKeys = [(key, value) | GuidingRow key value <- classified]
    rejectedWithKeys = [(key, value) | RejectedRow key value <- classified]
    pendingWithKeys = [(key, value) | PendingRow key value <- classified]
    retiredWithKeys = [(key, value) | RetiredRow key value <- classified]
    malformed = [value | DiagnosticRow value <- classified]
    diagnosticKey ReviewMemoryDiagnostic {memoryId, code} = (memoryId, code)

data ClassifiedRow
  = GuidingRow !(Text, Text) !AdjudicatedPracticeReview
  | RejectedRow !(Text, Text) !AdjudicatedPracticeReview
  | PendingRow !(Text, Text) !ValidatedPracticeReviewVerdict
  | RetiredRow !(Text, Text) !AdjudicatedPracticeReview
  | IgnoredRow
  | DiagnosticRow !ReviewMemoryDiagnostic

classifyRow :: ReviewRecallContext -> MemoryRow -> ClassifiedRow
classifyRow context@ReviewRecallContext {practice = wantedPractice} MemoryRow {memoryId, content} =
  case decodePracticeReviewMemory content of
    Left err -> DiagnosticRow (ReviewMemoryDiagnostic memoryId "invalid-envelope" err)
    Right (ProvisionalReview verdict) -> classifyVerdict verdict (classifyProvisional verdict)
    Right (ResolvedReview verdict resolution) -> classifyVerdict verdict (classifyResolved verdict resolution)
  where
    classifyVerdict verdict classified =
      let PracticeReviewVerdict {practice} = validatedVerdictValue verdict
       in if matchesPractices [practice] wantedPractice
            then classified
            else DiagnosticRow (ReviewMemoryDiagnostic memoryId "scope-mismatch" "envelope practice does not match the queried practice scope")

    classifyProvisional verdict =
      if verdictMatchesContext context verdict
        then PendingRow (reviewSortKey verdict memoryId) verdict
        else IgnoredRow

    classifyResolved verdict resolution =
      let adjudicated = AdjudicatedPracticeReview {verdict, resolution}
          PracticeReviewResolution {outcome, resultingApplicability} = validatedResolutionValue resolution
          matchesOriginal = verdictMatchesContext context verdict
       in case outcome of
            Accepted
              | maybe False (`appliesTo` context) resultingApplicability -> GuidingRow (reviewSortKey verdict memoryId) adjudicated
            Narrowed
              | maybe False (`appliesTo` context) resultingApplicability -> GuidingRow (reviewSortKey verdict memoryId) adjudicated
            Rejected
              | matchesOriginal -> RejectedRow (reviewSortKey verdict memoryId) adjudicated
            Superseded
              | matchesOriginal -> RetiredRow (reviewSortKey verdict memoryId) adjudicated
            _ -> IgnoredRow

verdictMatchesContext :: ReviewRecallContext -> ValidatedPracticeReviewVerdict -> Bool
verdictMatchesContext context validated =
  let PracticeReviewVerdict {practice, applicability} = validatedVerdictValue validated
      ReviewRecallContext {practice = wantedPractice} = context
   in matchesPractices [practice] wantedPractice && appliesTo applicability context

reviewSortKey :: ValidatedPracticeReviewVerdict -> Text -> (Text, Text)
reviewSortKey validated memoryId =
  let PracticeReviewVerdict {reviewId} = validatedVerdictValue validated
   in (reviewIdText reviewId, memoryId)

recallPracticeReviewChainIO :: PracticeReviewMemoryEnv -> ReviewId -> IO PracticeReviewChain
recallPracticeReviewChainIO PracticeReviewMemoryEnv {appEnv} reviewId =
  runAppIO appEnv (Memory.getSupersessionChain shikigamiMemorySpace (provisionalMemoryId reviewId)) >>= \case
    Left storeError -> ioError (userError ("failed to read practice-review chain: " <> show storeError))
    Right (Left readError) ->
      pure
        PracticeReviewChain
          { entries = [],
            diagnostics = [ReviewMemoryDiagnostic (idText (provisionalMemoryId reviewId)) "chain-read-failed" (Text.pack (show readError))]
          }
    Right (Right rows) -> do
      let orderedEntries = chainEntry <$> sortOn chainRowKey rows
          diagnostics = [entryDiagnostic | PracticeReviewChainEntry {diagnostic = Just entryDiagnostic} <- orderedEntries]
      pure PracticeReviewChain {entries = orderedEntries, diagnostics}
  where
    chainRowKey MemoryRow {createdAt, memoryId} = (createdAt, memoryId)

chainEntry :: MemoryRow -> PracticeReviewChainEntry
chainEntry MemoryRow {memoryId, status, supersededBy, supersedes, content} =
  case decodePracticeReviewMemory content of
    Right envelope ->
      PracticeReviewChainEntry
        { memoryId,
          status,
          supersededBy,
          supersedes,
          envelope = Just envelope,
          diagnostic = Nothing
        }
    Left detail ->
      PracticeReviewChainEntry
        { memoryId,
          status,
          supersededBy,
          supersedes,
          envelope = Nothing,
          diagnostic = Just (ReviewMemoryDiagnostic memoryId "invalid-envelope" detail)
        }
