{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Reading one bounded page of owner observations. SQL stays with each
-- owner; a page uses one read-only repeatable-read snapshot.
module FlowPack.Watchdog.Observation.Read (ObservationEffects, observePage) where

import Control.Lens ((%~), (&), (.~))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isRight, rights)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Observation
import FlowPack.Watchdog.Types
import FlowPack.Watchdog.Waiting qualified as Waiting
import FlowPack.Watchdog.Waiting.Read qualified as WaitingRead
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransactionNoRetry)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.Approval.Observation qualified as Approval
import Shikigami.Coordination.Observation qualified as Coordinator
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Resources (ResourceError)
import Shikigami.Execution.RootObservation qualified as Root
import Shikigami.Execution.Transcript qualified as ExecutionOwner
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as ExecutionWorkflow
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as ObjectiveOwner
import Shikigami.WorkerSession.Observation qualified as Session
import Shikigami.WorkerSession.Types qualified as SessionOwner
import Shikigami.Workspace.Process qualified as ProcessOwner
import Shikigami.Workspace.ProcessObservation qualified as Process
import Shikigami.Workspace.Types (WorkspaceError)

type ObservationEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

observePage :: (ObservationEffects es) => ObservationGrant -> ObservationBounds -> CoverageCursor -> Eff es (Either ObservationError ObservationPage)
observePage grant bounds supplied
  | durationTime bounds.statementTimeout <= 0 || durationTime bounds.lockTimeout <= 0 = pure (Left ObservationBoundsExceeded)
  | otherwise = do
      result <- tryError @StoreError (runTransactionNoRetry (observePageTx grant bounds supplied))
      case result of
        Left _ -> pure (Left ObservationUnavailable)
        Right (Left refusal) -> pure (Left refusal)
        Right (Right (page, associations, associationsComplete)) -> do
          public <- WaitingRead.observeWaiting bounds.statementTimeout (nub (concatMap subjectParents page.subjects)) associations
          let subjects = map (withPublicFacts page.observedAt associationsComplete public) page.subjects
              publicRefusals = [ObservationRefusal (subjectKind observed.subject) (subjectKeyText (subjectKey observed.subject)) RelationshipUnknown | observed <- subjects, observed.relationshipsComplete == Unknown]
              refusals = nub (page.refusals <> publicRefusals)
              complete = page.cursor.passClean && null refusals
              completion = if page.passCompleted == PassCompleted && not complete then PassIncomplete else page.passCompleted
              observed = page & #subjects .~ subjects & #refusals .~ refusals & #cursor . #passClean .~ complete & #passCompleted .~ completion
          pure (if Lazy.length (Aeson.encode observed) > 33554432 then Left ObservationBoundsExceeded else Right observed)

-- At most fifteen SQL statements for this metadata slice: transaction mode,
-- two timeouts, clock, three populations and eight set-based follow-up reads.
-- Public workflow headers and exact approval timer calls are separately bounded.
-- Individual statements have a finite timeout. Top-level subjects are capped
-- at 96, relationship inventories at 256; each owner caps nested rows and bytes.
-- The encoded page is capped at 32 MiB. A failed transaction or byte check
-- returns no page/cursor; callers retain the last accepted coverage cursor.
observePageTx :: ObservationGrant -> ObservationBounds -> CoverageCursor -> Transaction (Either ObservationError (ObservationPage, [Approval.ApprovalAssociation], Bool))
observePageTx grant bounds supplied = do
  Tx.sql "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
  Tx.sql (TextEncoding.encodeUtf8 ("SET LOCAL statement_timeout='" <> millis bounds.statementTimeout <> "ms'"))
  Tx.sql (TextEncoding.encodeUtf8 ("SET LOCAL lock_timeout='" <> millis bounds.lockTimeout <> "ms'"))
  instant <- Tx.statement () (preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz))))
  let cursor = if supplied.scope == Just (grantScope grant) && length supplied.exhausted < 3 then supplied else initialCursor
      shares = pageShares (limitValue (grantBudget grant)) cursor
      share kind = maybe 0 id (lookup kind shares)
      objectiveScope = case grantScope grant of AllObjectives -> Objective.AllOpenObjectives; SelectedObjectives ids -> Objective.OpenObjectivesIn ids
      sessionScope = case grantScope grant of AllObjectives -> Session.AllSessions; SelectedObjectives ids -> Session.SessionsForObjectives ids
      executionScope = case grantScope grant of AllObjectives -> Execution.AllExecutions; SelectedObjectives ids -> Execution.ExecutionsForObjectives ids
  objectiveRows <- if share Objectives == 0 then pure [] else Objective.observeOpenObjectives objectiveScope cursor.objectives (share Objectives)
  sessionRows <- if share Sessions == 0 then pure [] else Session.observeOpenSessions sessionScope cursor.sessions (share Sessions)
  executionRows <- if share Executions == 0 then pure [] else Execution.observeOpenExecutions executionScope cursor.executions (share Executions)
  let objectives = rights (map snd objectiveRows)
      sessions = rights (map snd sessionRows)
      executions = rights (map snd executionRows)
      objectiveIds = map (.objectiveId) objectives
      sessionIds = nub (map (.sessionId) sessions <> concatMap (mapMaybe (.sessionId) . (.assignments)) objectives)
  coordinators <- whenNonEmpty objectiveIds Coordinator.observeCoordinators
  relatedSessions <- whenNonEmpty sessionIds Session.observeSessionsFor
  scopedSessions <- whenNonEmpty objectiveIds Session.observeSessionsUnderObjectives
  let relatedSessionIds = nub (sessionIds <> either (const []) (map fst) scopedSessions)
  relatedExecutions <- whenNonEmpty relatedSessionIds Execution.observeExecutionsForSessions
  objectiveExecutions <- whenNonEmpty objectiveIds Execution.observeExecutionsUnderObjectives
  let coordinateValues = either (const []) (rights . map snd) coordinators
      sessionValues = nub (either (const []) (rights . map snd) relatedSessions <> either (const []) (rights . map snd) scopedSessions)
      executionValues = nub (either (const []) (rights . map snd) relatedExecutions <> either (const []) (rights . map snd) objectiveExecutions)
      bareSubjects =
        map
          ( objectiveSubject
              coordinateValues
              sessionValues
              executionValues
              (either (const False) (all (isRight . snd)) coordinators)
              (either (const False) (all (isRight . snd)) relatedSessions && either (const False) (all (isRight . snd)) scopedSessions)
              (either (const False) (all (isRight . snd)) relatedExecutions && either (const False) (all (isRight . snd)) objectiveExecutions)
          )
          objectives
          <> map (sessionSubject executionValues (either (const False) (all (isRight . snd)) relatedExecutions)) sessions
          <> map executionSubject executions
      rootIds = nub (concatMap (rootsOf . (.metadata)) bareSubjects)
      operationIds = nub (concatMap (operationsOf . (.metadata)) bareSubjects)
      parents = nub (concatMap subjectParents bareSubjects)
  rootRows <- whenNonEmpty rootIds Root.observeRoots
  processRows <- whenNonEmpty operationIds Process.observeUnsettledProcesses
  associations <- whenNonEmpty (map (\coordinate -> (WorkflowName coordinate.name, WorkflowId coordinate.identifier)) parents) Approval.observeApprovalAssociations
  let -- Fold separate owner error domains without replacing them with a shared
      -- technical error type. Any relation refusal remains unknown.
      coordinatorComplete = either (const False) (all (isRight . snd)) coordinators
      sessionsComplete = either (const False) (all (isRight . snd)) relatedSessions && either (const False) (all (isRight . snd)) scopedSessions
      executionsComplete = either (const False) (all (isRight . snd)) relatedExecutions && either (const False) (all (isRight . snd)) objectiveExecutions
      populationRefusals =
        [ObservationRefusal Objectives key CorruptMetadata | (key, Left _) <- objectiveRows]
          <> [ObservationRefusal Sessions (SessionOwner.workerSessionIdText key) CorruptMetadata | (key, Left _) <- sessionRows]
          <> [ObservationRefusal Executions (ExecutionOwner.executionIdText key) CorruptMetadata | (key, Left _) <- executionRows]
      relationRefusals =
        [ObservationRefusal Objectives "coordinator-relations" RelationshipUnknown | not coordinatorComplete]
          <> [ObservationRefusal Sessions "session-relations" RelationshipUnknown | not sessionsComplete]
          <> [ObservationRefusal Executions "execution-relations" RelationshipUnknown | not executionsComplete]
      refusals = populationRefusals <> relationRefusals <> [ObservationRefusal (subjectKind observed.subject) (subjectKeyText (subjectKey observed.subject)) RelationshipUnknown | observed <- subjects, observed.relationshipsComplete == Unknown]
      allClean = cursor.passClean && null refusals
      done = nub (cursor.exhausted <> [kind | (kind, count) <- shares, count > 0, populationSize kind objectiveRows sessionRows executionRows < count])
      completion = if length done < 3 then PassContinuing else if allClean then PassCompleted else PassIncomplete
      next =
        CoverageCursor
          (Just (grantScope grant))
          (if Objectives `elem` done then Nothing else lastKey cursor.objectives (mapMaybe (either (const Nothing) Just . ObjectiveOwner.parseObjectiveId . fst) objectiveRows))
          (if Sessions `elem` done then Nothing else lastKey cursor.sessions (map fst sessionRows))
          (if Executions `elem` done then Nothing else lastKey cursor.executions (map fst executionRows))
          done
          (nextAfter cursor.nextKind)
          allClean
      subjects = map (withCoreFacts instant rootRows processRows) bareSubjects
      page = ObservationPage instant next completion subjects refusals
      invalidKeys = any (either (const True) (const False) . ObjectiveOwner.parseObjectiveId . fst) objectiveRows
  pure
    if invalidKeys
      then Left ObservationCorruptKey
      else if Lazy.length (Aeson.encode page) > 33554432 then Left ObservationBoundsExceeded else Right (page, either (const []) id associations, isRight associations)
  where
    millis duration = Text.pack (show (max 1 (ceiling (durationTime duration * 1000) :: Integer)))
    nextAfter Objectives = Sessions
    nextAfter Sessions = Executions
    nextAfter Executions = Objectives
    lastKey prior values = case reverse values of [] -> prior; value : _ -> Just value
    populationSize Objectives objectives _ _ = length objectives
    populationSize Sessions _ sessions _ = length sessions
    populationSize Executions _ _ executions = length executions

whenNonEmpty :: [a] -> (NonEmpty a -> Transaction (Either e [b])) -> Transaction (Either e [b])
whenNonEmpty values action = maybe (pure (Right [])) action (NonEmpty.nonEmpty values)

objectiveSubject :: [Coordinator.CoordinatorObservation] -> [Session.SessionObservation] -> [Execution.ExecutionObservation] -> Bool -> Bool -> Bool -> Objective.ObjectiveObservation -> SubjectObservation
objectiveSubject coordinators sessions executions coordinatorsComplete sessionsComplete executionsComplete objective =
  SubjectObservation (ObjectiveCoordinator objective.objectiveId) (Just objective.objectiveId) mark waits (ObjectiveEvidence objective.objectiveId objective.revision :| []) completeness (ObjectiveMetadata objective coordinator assigned activeExecutions) [] [] [] []
  where
    coordinator = case filter ((== objective.objectiveId) . (.objectiveId)) coordinators of [value] -> Just value; _ -> Nothing
    assignedIds = mapMaybe (.sessionId) objective.assignments
    assigned = filter (\session -> session.sessionId `elem` assignedIds || session.boundObjective == Just objective.objectiveId) sessions
    activeExecutions = filter ((== Just objective.objectiveId) . (.objective)) executions
    latestRevision = coordinator >>= (.latestRevision)
    listener = coordinator >>= (\value -> case value.listeners of first : _ -> Just first.after; [] -> Nothing)
    terminal = if maybe False (.terminal) coordinator then CoordinatorTerminal else CoordinatorOpen
    mark = CoordinatorMark (CoordinatorActivity objective.status objective.revision latestRevision listener objective.integratedCursors terminal)
    waits = [BlockedObjective | objective.status == ObjectiveOwner.Blocked]
    completeness = if coordinatorsComplete && sessionsComplete && executionsComplete && objective.relationshipsComplete && maybe False (.relationshipsComplete) coordinator && all (.assignmentObserved) assigned && all activityComplete activeExecutions then Complete else Unknown

sessionSubject :: [Execution.ExecutionObservation] -> Bool -> Session.SessionObservation -> SubjectObservation
sessionSubject executions executionsComplete session = SubjectObservation (WorkerSession session.sessionId) session.boundObjective mark waits (SessionEvidence session.sessionId session.eventCursor :| []) completeness (SessionMetadata session related) [] [] [] []
  where
    related = filter (\execution -> Just execution.executionId == session.executionId || Just execution.runId == session.childWorkflowId) executions
    mark = SessionMark (SessionActivity session.revision session.eventCursor session.consumedCursor session.nextSequence session.epoch session.phase session.assignmentPhase (map executionActivity related))
    waits = [AssignmentParked | session.phase == SessionOwner.Parked || session.assignmentPhase == Just SessionOwner.AssignmentParked] <> concatMap permissionWaits related
    completeness = if executionsComplete && session.assignmentObserved && all activityComplete related then Complete else Unknown

executionSubject :: Execution.ExecutionObservation -> SubjectObservation
executionSubject execution = SubjectObservation (Execution execution.executionId) execution.objective mark waits (ExecutionEvidence execution.executionId execution.cursor :| []) completeness (ExecutionMetadata execution) [] [] [] []
  where
    mark = ExecutionMark (executionActivity execution)
    waits = permissionWaits execution
    completeness = if execution.activityComplete && all (.attemptsComplete) execution.operations then Complete else Unknown

subjectKind :: Subject -> SubjectKind
subjectKind (ObjectiveCoordinator _) = Objectives
subjectKind (WorkerSession _) = Sessions
subjectKind (Execution _) = Executions

executionsOf :: SubjectMetadata -> [Execution.ExecutionObservation]
executionsOf (ObjectiveMetadata _ _ _ executions) = executions
executionsOf (SessionMetadata _ executions) = executions
executionsOf (ExecutionMetadata execution) = [execution]

rootsOf :: SubjectMetadata -> [ExecutionRootId]
rootsOf metadata = nub (ownerRoots <> mapMaybe (.rootId) (executionsOf metadata))
  where
    ownerRoots = case metadata of
      ObjectiveMetadata objective coordinator sessions _ -> mapMaybe (.rootId) objective.assignments <> map (.rootId) sessions <> maybe [] (mapMaybe (.rootId) . (.runs)) coordinator
      SessionMetadata session _ -> [session.rootId]
      ExecutionMetadata execution -> maybe [] pure execution.rootId

operationsOf :: SubjectMetadata -> [OperationId]
operationsOf = nub . concatMap (\execution -> map (.operationId) execution.operations <> maybe [] pure execution.activeOperation) . executionsOf

subjectParents :: SubjectObservation -> [Waiting.WorkflowCoordinate]
subjectParents subject = nub (parents subject.metadata <> concatMap (\execution -> [executionParent execution, agentParent execution.runId.unWorkflowId]) (executionsOf subject.metadata))
  where
    agentParent identifier = Waiting.WorkflowCoordinate agentRunWorkflowName.unWorkflowName identifier
    executionParent execution = Waiting.WorkflowCoordinate ExecutionWorkflow.workflowName.unWorkflowName (ExecutionOwner.executionWorkflowId execution.executionId).unWorkflowId
    sessionParent session = maybe [] (pure . agentParent . (.unWorkflowId)) session.childWorkflowId
    parents (ObjectiveMetadata _ coordinator sessions _) = maybe [] (\value -> map (agentParent . (.runId)) value.runs <> map (\listener -> Waiting.WorkflowCoordinate listener.ownerName listener.ownerId) value.listeners) coordinator <> concatMap sessionParent sessions
    parents (SessionMetadata session _) = sessionParent session
    parents (ExecutionMetadata _) = []

appendEvidence :: NonEmpty EvidenceRef -> [EvidenceRef] -> NonEmpty EvidenceRef
appendEvidence prior [] = prior
appendEvidence prior (first : rest) = prior <> (first :| rest)

withCoreFacts :: UTCTime -> Either ResourceError [(ExecutionRootId, Either ResourceError Root.RootObservation)] -> Either WorkspaceError [(OperationId, Either WorkspaceError Process.ProcessObservation)] -> SubjectObservation -> SubjectObservation
withCoreFacts instant rootRows processRows subject =
  subject
    & #roots .~ roots
    & #processes .~ processes
    & #waits .~ (filter live subject.waits <> [CommandWait process.deadline process.operationId | process <- processes, process.phase `elem` [ProcessOwner.ProcessLaunchRequested, ProcessOwner.ProcessRunning], not process.receiptObserved, process.deadline > instant])
    & #evidence .~ appendEvidence subject.evidence (map (\root -> RootEvidence root.rootId root.revision) roots <> map (ProcessEvidence . (.operationId)) processes)
    & #relationshipsComplete .~ (if subject.relationshipsComplete == Complete && rootsComplete && processesComplete then Complete else Unknown)
  where
    requiredRoots = rootsOf subject.metadata
    requiredOperations = operationsOf subject.metadata
    roots = [root | (identifier, Right root) <- either (const []) id rootRows, identifier `elem` requiredRoots]
    processes = [process | (identifier, Right process) <- either (const []) id processRows, identifier `elem` requiredOperations]
    rootsComplete = null requiredRoots || case rootRows of Left _ -> False; Right _ -> all (`elem` map (.rootId) roots) requiredRoots
    processesComplete = null requiredOperations || case processRows of Left _ -> False; Right rows -> all (\(identifier, outcome) -> identifier `notElem` requiredOperations || isRight outcome) rows
    live (PermissionWait deadline) = deadline > instant
    live fact = case fact of CommandWait deadline _ -> deadline > instant; _ -> True

withPublicFacts :: UTCTime -> Bool -> Waiting.WaitingPage -> SubjectObservation -> SubjectObservation
withPublicFacts instant associationsComplete public subject =
  subject
    & #workflows .~ workflows
    & #approvals .~ approvals
    & #waits %~ (<> [ApprovalWait deadline approval.review | approval <- approvals, approval.phase == Waiting.ApprovalPending, Just deadline <- [approval.until], deadline > max instant approval.observedAt])
    & #evidence .~ appendEvidence subject.evidence (map (ApprovalEvidence . (.review)) approvals)
    & #relationshipsComplete .~ (if subject.relationshipsComplete == Complete && complete then Complete else Unknown)
  where
    parents = subjectParents subject
    workflows = filter ((`elem` parents) . (.workflow)) public.workflows
    approvals = filter ((`elem` parents) . (.parent)) public.approvals
    knownApprovalParents = map (.parent) approvals
    complete =
      (null parents || associationsComplete)
        && not (any (`elem` parents) public.unknownParents)
        && not (any (\header -> header.status == Waiting.HeaderSuspended && header.workflow `notElem` knownApprovalParents && not (checkpointParent header.workflow)) workflows)
    checkpointParent parent = case subject.metadata of
      ObjectiveMetadata _ (Just coordinator) _ _ -> any (\listener -> listener.ownerName == parent.name && listener.ownerId == parent.identifier) coordinator.listeners
      _ -> False

executionActivity :: Execution.ExecutionObservation -> ExecutionActivity
executionActivity execution = ExecutionActivity execution.revision execution.cursor execution.phase execution.activeOperation execution.uncertainOperations execution.pendingReceipts

permissionWaits :: Execution.ExecutionObservation -> [WaitingFact]
permissionWaits execution = case (execution.phase, execution.activePermission) of
  (ExecutionOwner.Parked, Just permission) | permission.resolution == Nothing -> [PermissionWait permission.expiresAt]
  _ -> []

activityComplete :: Execution.ExecutionObservation -> Bool
activityComplete execution = execution.activityComplete && all (.attemptsComplete) execution.operations
