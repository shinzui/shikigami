{-# LANGUAGE DataKinds #-}

-- | One bounded decision or accepted command per generation. Long model and
-- worker work lives in accepted executors; this controller only observes it.
module Shikigami.Coordination.Workflow (registry, workflow) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (find, nubBy)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff)
import Effectful.Exception (throwIO)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (scheduleTimerOnceTx)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), continueAsNew, currentRunGeneration, currentWorkflow, restoreSeed, step)
import Keiro.Workflow.Awakeable (cancelAwakeable)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Agent.Name (agentNameText)
import Shikigami.App (AppEffects)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Coordination.Checkpoint (Checkpoint (..), Provider (..))
import Shikigami.Coordination.Commands qualified as Commands
import Shikigami.Coordination.Decision
import Shikigami.Coordination.Direct qualified as Direct
import Shikigami.Coordination.Identity
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Coordination.Wake qualified as Wake
import Shikigami.Decision.Contract
import Shikigami.Execution.Driver qualified as Execution
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Execution.Start qualified as Execution
import Shikigami.Execution.Transcript (ExecutionError (..), ExecutionPhase (Succeeded))
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command (Command (RecordProgress))
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime (ObjectiveRuntime (..))
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Shikigami.Program.Decision.Adaptive
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.WorkerSession.Capability qualified as Workers
import Shikigami.WorkerSession.Handoff (TransferOutcome (..))
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Integration (IntegrationOutcome (..))
import Shikigami.WorkerSession.Position
import Shikigami.WorkerSession.Types qualified as Session

registry :: Maybe Runtime.Runtime -> WorkflowRegistry AppEffects
registry runtime = Map.singleton Generated.workflowName (WorkflowDef (\_ -> workflow runtime Nothing))

workflow :: Maybe Runtime.Runtime -> Maybe Admission -> Eff (Workflow : AppEffects) DeliveryResult
workflow configured initial = do
  seed <- restoreSeed initialSeed
  admission <- step (StepName "ingest-adaptive") (maybe (throwIO (userError "adaptive coordinator resumed without its admitted origin")) pure (seed.admission <|> initial))
  native <- currentWorkflow
  unless (native == (Generated.workflowName, admittedAdaptiveWorkflowId admission)) (throwIO (userError "adaptive coordinator workflow identity mismatch"))
  runtime <- maybe (throwIO (TransientBehaviorFailure "adaptive providers unavailable")) pure configured
  liftIO (Runtime.validateAdmission runtime admission) >>= require
  let seeded = seed & #admission .~ Just admission & #concurrency .~ (if isNothing seed.admission then admission.organization.maximumConcurrency else seed.concurrency)
  current <- journal runtime "adaptive-checkpoint" (liftIO ((Runtime.checkpoint runtime admission).current admission.objective.objectiveId) >>= require)
  now <- liftIO getCurrentTime
  outcome <-
    if now >= admission.organization.cutoff || current.objective.status /= Open
      then pure (result current seeded (if now >= admission.organization.cutoff then "CutoffReached" else "ObjectiveUnavailable") Nothing)
      else do
        events <- journal runtime "adaptive-events" (liftIO (observe runtime admission seeded.sessions) >>= sessionResult)
        case events of
          Left failure -> stopped current seeded failure
          Right observed -> do
            let findings = concatMap snd observed
            latest <- if map fst observed == seeded.sessions then pure current else journal runtime "adaptive-findings-checkpoint" (liftIO ((Runtime.checkpoint runtime admission).current admission.objective.objectiveId) >>= require)
            let active ready = maybe False (\assignment -> assignment.definition.state `notElem` [Done, Withdrawn]) (either (const Nothing) Just (Commands.assignmentFor latest.objective ready.assignmentId))
                state = seeded & #ready %~ filter active & #sessions .~ map fst observed
                changed = state.observed /= Just (Runtime.mark latest.objective) || not (null findings)
            case state.transfer of
              Just transfer -> reconcileTransfer runtime admission latest state transfer
              Nothing -> case state.pending of
                Just pending | maybe False (meaningChanged (Runtime.mark latest.objective)) state.observed -> rotate (state & #pending .~ Nothing & #ready .~ [] & #reflect .~ True & #refusal .~ Just "Assignment meaning changed before pending dispatch")
                Just pending -> dispatchPending runtime admission latest state pending
                Nothing | state.reflect || changed -> decide runtime admission latest state findings
                Nothing -> dispatchReadyOrWait runtime admission latest state
  generation <- currentRunGeneration
  _ <- journal runtime "adaptive-terminal" (liftIO (Runtime.note runtime admission (Runtime.operationKey "terminal" (toJSON (admission.run, generation))) outcome) >>= objectiveResult)
  pure outcome
  where
    stopped current state failure
      | failure == Session.SessionStorageUnavailable = throwIO (TransientBehaviorFailure "adaptive worker observation unavailable")
      | otherwise = pure (result current state "Refused" (Just (Text.take 512 (Text.pack (show failure)))))

meaningChanged :: EvidenceMark -> EvidenceMark -> Bool
meaningChanged current previous = current.instructions /= previous.instructions || current.criteria /= previous.criteria || current.graph /= previous.graph

reconcileTransfer :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> TransferReference -> Eff (Workflow : AppEffects) DeliveryResult
reconcileTransfer runtime admission checkpoint state transfer = do
  outcome <- journal runtime "adaptive-handoff" do
    response <- liftIO (Commands.call runtime admission (Commands.CommandIntent transfer.scope transfer.operationId (Workers.ReconcileWorker transfer.sessionId)))
    case response of
      Right (Workers.TransferObserved HandoffUnavailable) -> throwIO (TransientBehaviorFailure "adaptive handoff authority unavailable")
      _ -> sessionResult response
  case outcome of
    Right (Workers.TransferObserved (HandoffEstablished _ _)) -> rotate (state & #transfer .~ Nothing & #reflect .~ True)
    Right (Workers.TransferObserved HandoffPending) -> waitForCheckpoint runtime admission checkpoint state
    Right (Workers.TransferObserved HandoffUnavailable) -> throwIO (TransientBehaviorFailure "adaptive handoff authority unavailable")
    Right (Workers.TransferObserved HandoffConflict) -> pure (result checkpoint state "Refused" (Just "HandoffConflict"))
    Left err -> pure (result checkpoint state "Refused" (Just (Text.pack (show err))))
    _ -> throwIO (userError "adaptive handoff returned an unexpected command result")

journal :: (ToJSON a, FromJSON a) => Runtime.Runtime -> Text -> Eff (Workflow : AppEffects) a -> Eff (Workflow : AppEffects) a
journal runtime label action = step (StepName label) $ do
  liftIO (runtime.beforeStep (StepName label))
  value <- action
  liftIO (runtime.afterStep (StepName label))
  pure value

require :: Either ObjectiveError a -> Eff (Workflow : AppEffects) a
require = either refused pure
  where
    refused ObjectiveConflict = throwIO (TransientBehaviorFailure "adaptive checkpoint changed during observation")
    refused ObjectiveUnavailable = throwIO (TransientBehaviorFailure "adaptive objective provider unavailable")
    refused err = throwIO (DecisionAbort (decisionFailure EvidenceFailure (Text.take 512 (Text.pack (show err)))))

objectiveResult :: Either ObjectiveError a -> Eff (Workflow : AppEffects) (Either ObjectiveError a)
objectiveResult (Left ObjectiveUnavailable) = throwIO (TransientBehaviorFailure "adaptive objective acknowledgement unavailable")
objectiveResult value = pure value

sessionResult :: Either Session.SessionError a -> Eff (Workflow : AppEffects) (Either Session.SessionError a)
sessionResult value = case value of
  Left Session.SessionStorageUnavailable -> throwIO (TransientBehaviorFailure "adaptive worker command acknowledgement unavailable")
  _ -> pure value

result :: Checkpoint -> Seed -> Text -> Maybe Text -> DeliveryResult
result checkpoint seed status refusal = DeliveryResult checkpoint.objective.objectiveId checkpoint.objective.revision seed.lastDecision status refusal

rotate :: Seed -> Eff (Workflow : AppEffects) a
rotate = continueAsNew

observe :: Runtime.Runtime -> Admission -> [SessionReference] -> IO (Either Session.SessionError [(SessionReference, [Session.RetainedFinding])])
observe runtime admission references = fmap sequence $ forM references $ \reference -> do
  let operation = Runtime.operationKey "read-events" (toJSON (admission.run, reference.sessionId, reference.after))
      intent = Commands.CommandIntent reference.scope operation (Workers.ReadWorkerEvents reference.sessionId reference.after (either (error . show) id (Input.parseSessionLimit 100)))
  Commands.call runtime admission intent >>= \case
    Left err -> pure (Left err)
    Right (Workers.WorkerEvents events) -> do
      findings <- forM [receipt | Session.EventReceipt {event = Session.ResultAvailable receipt} <- events] $ \receipt ->
        Commands.call runtime admission (Commands.CommandIntent reference.scope (Runtime.operationKey "read-result" (toJSON receipt)) (Workers.ReadWorkerResult receipt.sessionId receipt.assignmentId)) <&> \case
          Right (Workers.WorkerResult (Just (actual, value))) | actual == receipt -> Right (Session.RetainedFinding receipt ((.output) <$> value))
          Left err -> Left err
          _ -> Left Session.SessionBindingConflict
      integrated <-
        if null findings && not (any (\event -> case event.event of Session.TransferStatusChanged _ Session.TransferEstablished -> True; _ -> False) events)
          then pure (Right ())
          else integrateThrough runtime admission reference (foldr max reference.after (map (.cursor) events)) 16
      pure $ do
        values <- sequence findings
        integrated
        let after = foldr max reference.after (map (.cursor) events)
        pure (reference & #after .~ after, values)
    _ -> pure (Left Session.SessionBindingConflict)

-- One logical integration key per native batch; recovery never reuses an older
-- accepted batch as if it acknowledged a later cursor.
integrateThrough :: Runtime.Runtime -> Admission -> SessionReference -> StateRevision "worker-event" -> Int -> IO (Either Session.SessionError ())
integrateThrough runtime admission reference through remaining
  | remaining <= 0 = pure (Left Session.SessionStorageUnavailable)
  | otherwise = do
      observed <- Commands.call runtime admission (Commands.CommandIntent reference.scope (Runtime.operationKey "integration-state" (toJSON (reference.sessionId, through))) (Workers.InspectWorker reference.sessionId beforeMessages Input.firstAssignmentPageSize))
      case observed of
        Right (Workers.WorkerInspected page)
          | page.state.consumedCursor >= through -> pure (Right ())
          | otherwise -> do
              answer <- Commands.call runtime admission (Commands.CommandIntent reference.scope (Runtime.operationKey "integrate" (toJSON (reference.sessionId, page.state.consumedCursor))) (Workers.IntegrateWorkerEvents reference.sessionId))
              case answer of
                Right (Workers.EventsIntegratedReply (EventsIntegrated _ cursor)) | cursor > page.state.consumedCursor -> integrateThrough runtime admission reference through (remaining - 1)
                Right (Workers.EventsIntegratedReply (EventsCaughtUp cursor)) | cursor >= through -> pure (Right ())
                Right (Workers.EventsIntegratedReply EventsConflict) -> pure (Left (Session.SessionInputRefused "checkpoint needs explicit revalidation of changed assignment meaning"))
                Left err -> pure (Left err)
                _ -> pure (Left Session.SessionStorageUnavailable)
        Left err -> pure (Left err)
        _ -> pure (Left Session.SessionBindingConflict)

decide :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> [Session.RetainedFinding] -> Eff (Workflow : AppEffects) DeliveryResult
decide runtime admission checkpoint state findings = do
  generation <- currentRunGeneration
  let operation = Runtime.operationKey "decision" (toJSON (admission.run, generation, checkpoint.objective.revision))
      coordinates = object ["format" .= (1 :: Int), "objectiveId" .= checkpoint.objective.objectiveId, "checkpointRevision" .= checkpoint.objective.revision, "instructionsRevision" .= checkpoint.objective.instructionsRevision, "criteriaRevision" .= checkpoint.objective.criteriaRevision, "operationId" .= operation]
      input = AdaptiveInput admission.instructions (Text.decodeUtf8 (Lazy.toStrict (Aeson.encode (object ["checkpoint" .= checkpoint, "pinnedPolicy" .= (admission.organization & #workspaces .~ checkpoint.workspaces), "proposalCoordinates" .= coordinates, "findings" .= findings, "directResults" .= state.directResults, "refusal" .= state.refusal, "proposalVocabulary" .= vocabulary]))))
  output <- Decision.runDecisionAccepted (Runtime.decisionEnv runtime admission) (Runtime.decisionHost runtime admission) admission.decisions (Decision.decide adaptiveStep adaptiveModel input)
  proposal <- either (throwIO . DecisionAbort) pure (decodeProposal output)
  unless (proposal.operationId == operation) (throwIO (DecisionAbort (decisionFailure ContractMismatch "adaptive proposal operation differs from its prepared checkpoint")))
  accepted <- journal runtime "adaptive-validation" do
    value <-
      liftIO $
        if operationallySupported admission checkpoint proposal
          then Runtime.accept runtime admission checkpoint proposal
          else pure (Left ObjectiveDenied)
    objectiveResult value
  case accepted of
    Left ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "adaptive decision acknowledgement unavailable")
    Left ObjectiveConflict -> rotate (state & #reflect .~ True & #observed .~ Just (Runtime.mark checkpoint.objective) & #refusal .~ Just "Checkpoint changed before decision admission")
    Left err -> pure (result checkpoint state "Refused" (Just (Text.take 512 (Text.pack (show err)))))
    Right decision -> do
      let expected = Runtime.mark checkpoint.objective & #graph .~ Runtime.graphMark (map (.assignment) decision.arrangement)
      rotate (state & #lastDecision .~ Just decision.proposal.operationId & #pending .~ Just (PendingDecision decision.proposal.operationId 0) & #observed .~ Just expected & #reflect .~ False & #refusal .~ Nothing)

operationallySupported :: Admission -> Checkpoint -> P.Proposal -> Bool
operationallySupported admission checkpoint proposal = all supported proposal.changes
  where
    placement key = find ((== key) . (.assignment.assignmentId)) checkpoint.arrangement
    top key = maybe False (isNothing . (.parent)) (placement key)
    supported = \case
      P.DirectWork key _ -> maybe False (Direct.supported admission) (placement key)
      P.FollowUpContext key _ -> top key
      P.EscalateModel key _ -> top key
      P.TransferAssignment key _ _ -> top key
      _ -> True

dispatchPending :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> PendingDecision -> Eff (Workflow : AppEffects) DeliveryResult
dispatchPending runtime admission checkpoint state pending = do
  retained <- journal runtime "adaptive-load-decision" (liftIO ((Runtime.checkpoint runtime admission).observe admission.objective.objectiveId pending.operationId) >>= require)
  decision <- maybe (throwIO (userError "accepted adaptive manifest is missing")) pure retained
  let operations = Commands.operations decision
      next = state & #pending .~ (if pending.nextOperation + 1 >= length operations then Nothing else Just (pending & #nextOperation %~ (+ 1)))
  case drop pending.nextOperation operations of
    [] -> rotate (state & #pending .~ Nothing)
    operation : _ -> case operation.change of
      P.CreateAssignment placement
        | isJust placement.parent -> rotate next
        | otherwise -> rotate (next & #ready %~ replaceReady (ReadyAssignment placement.assignment.assignmentId operation.operationId decision.proposal.operationId))
      P.NarrowAssignment key _ -> rotate (next & #ready %~ replaceReady (ReadyAssignment key operation.operationId decision.proposal.operationId))
      P.ChangeConcurrency maximum -> rotate (next & #concurrency .~ maximum)
      P.AwaitAssignments _ -> rotate next
      P.IntegrateResult {} -> rotate (next & #reflect .~ True)
      P.ProposeCompletion {} -> pure (DeliveryResult checkpoint.objective.objectiveId checkpoint.objective.revision (Just decision.proposal.operationId) "CompletionProposed" Nothing)
      _ -> case Commands.operationForAssignment operation of
        Nothing -> rotate next
        Just key -> dispatch runtime admission checkpoint state next decision operation key

replaceReady :: ReadyAssignment -> [ReadyAssignment] -> [ReadyAssignment]
replaceReady ready previous = filter ((/= ready.assignmentId) . (.assignmentId)) previous <> [ready]

dispatchReadyOrWait :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> Eff (Workflow : AppEffects) DeliveryResult
dispatchReadyOrWait runtime admission checkpoint state = do
  readiness <- journal runtime "adaptive-ready" (liftIO (selectReady runtime admission checkpoint state))
  case readiness of
    Left err -> sessionResult (Left err) >> pure (result checkpoint state "Refused" (Just (Text.pack (show err))))
    Right Nothing -> waitForCheckpoint runtime admission checkpoint state
    Right (Just ready) -> do
      -- The most recent accepted decision pins the current desired arrangement.
      -- Ready entries retain their own original stable command identities.
      retained <- journal runtime "adaptive-load-decision" (liftIO (latestDecision runtime admission (fromMaybe ready.decisionId state.lastDecision)) >>= objectiveResult)
      case retained of
        Left err -> require (Left err)
        Right decision -> do
          placement <- maybe (throwIO (userError "ready adaptive placement missing")) pure (find ((== ready.assignmentId) . (.assignment.assignmentId)) checkpoint.arrangement)
          let operation = P.ExecutableOperation ready.operationId (P.CreateAssignment placement)
              next = state & #ready %~ filter ((/= ready.assignmentId) . (.assignmentId))
          dispatch runtime admission checkpoint state next decision operation ready.assignmentId

-- A ready reference must retain which committed decision admitted its graph.
latestDecision :: Runtime.Runtime -> Admission -> OperationId -> IO (Either ObjectiveError P.AcceptedDecision)
latestDecision runtime admission decisionId = do
  let provider = Runtime.checkpoint runtime admission
  -- Created-assignment references are extended with this binding by the
  -- workflow; an absent decision is corruption, never a reason to sample anew.
  provider.observe admission.objective.objectiveId decisionId <&> (>>= maybe (Left ObjectiveMissing) Right)

selectReady :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> IO (Either Session.SessionError (Maybe ReadyAssignment))
selectReady runtime admission checkpoint state = do
  busy <- fmap sequence $ forM state.sessions $ \reference -> do
    let inspect position = Commands.call runtime admission (Commands.CommandIntent reference.scope (Runtime.operationKey "inspect" (toJSON (reference.sessionId, position))) (Workers.InspectWorker reference.sessionId position Input.firstAssignmentPageSize))
    inspect beforeMessages >>= \case
      Left err -> pure (Left err)
      Right (Workers.WorkerInspected first) -> do
        let position = either (error . show) id (parseMessagePosition (max (-1) (revisionNumber first.state.nextSequence - 21)))
        inspect position <&> \case
          Right (Workers.WorkerInspected page) -> Right (isJust page.state.activeAssignment || page.state.phase `elem` [Session.Active, Session.Parked, Session.Unresolved, Session.Transferring] || any (\message -> message.phase == Session.Queued) page.messages)
          Left err -> Left err
          _ -> Left Session.SessionBindingConflict
      _ -> pure (Left Session.SessionBindingConflict)
  pure $ do
    current <- busy
    if length (filter id current) >= state.concurrency
      then Right Nothing
      else Right (find (\ready -> maybe False (Commands.ready checkpoint.objective) (either (const Nothing) Just (Commands.assignmentFor checkpoint.objective ready.assignmentId))) state.ready)

dispatch :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> Seed -> P.AcceptedDecision -> P.ExecutableOperation -> ObjectiveAssignmentId -> Eff (Workflow : AppEffects) DeliveryResult
dispatch runtime admission checkpoint state next decision operation key = do
  assignment <- require (Commands.assignmentFor checkpoint.objective key)
  placement <- maybe (throwIO (userError "adaptive assignment has no pinned placement")) pure (find ((== key) . (.assignment.assignmentId)) checkpoint.arrangement)
  if assignment.definition.state `elem` [Done, Withdrawn]
    then rotate next
    else
      if placement.assignment.owner == admission.run.identity
        then direct runtime admission checkpoint state next decision operation placement assignment
        else do
          scoped <- journal runtime "adaptive-scope" (liftIO (Commands.retainScope runtime admission decision checkpoint state.sessions) >>= objectiveResult) >>= require
          scope <- maybe (throwIO (userError "adaptive worker scope is empty")) pure scoped
          fresh <- journal runtime "adaptive-dispatch-checkpoint" (liftIO ((Runtime.checkpoint runtime admission).current admission.objective.objectiveId) >>= require)
          current <- require (Commands.assignmentFor fresh.objective key)
          found <- journal runtime "adaptive-find" (liftIO (Commands.call runtime admission (Commands.CommandIntent scope (Runtime.operationKey "find" (toJSON operation.operationId)) (Workers.FindWorker (Input.workerCoordinate (objectiveAssignmentIdText key))))) >>= sessionResult)
          case found of
            Left err -> pure (result fresh state "Refused" (Just (Text.pack (show err))))
            Right (Workers.WorkerFound worker) -> do
              when (case operation.change of P.TransferAssignment {} -> True; _ -> False) do
                idle <- journal runtime "adaptive-transfer-ready" $ do
                  let position = either (error . show) id (parseMessagePosition (max (-1) (revisionNumber worker.nextSequence - 21)))
                  inspected <- liftIO (Commands.call runtime admission (Commands.CommandIntent scope (Runtime.operationKey "transfer-ready" (toJSON operation.operationId)) (Workers.InspectWorker worker.sessionId position Input.firstAssignmentPageSize))) >>= sessionResult
                  case inspected of
                    Right (Workers.WorkerInspected page) -> pure (page.state.phase == Session.Idle && isNothing page.state.activeAssignment && page.state.consumedCursor == page.state.eventCursor && all (\message -> message.phase == Session.AssignmentFinished) page.messages)
                    _ -> pure False
                unless idle (throwIO (DecisionAbort (decisionFailure EvidenceFailure "transfer requires an idle, fully integrated worker session")))
              intent <- journal runtime "adaptive-intent" $ do
                supplied <- require (Commands.instruction fresh.objective current (provided operation.change) (selected state key operation.change))
                let command = case operation.change of
                      P.TransferAssignment _ target workspace -> Workers.TransferWorker worker.sessionId worker.revision worker.epoch workspace target
                      _ -> Workers.SendWorker worker.sessionId worker.revision worker.epoch supplied
                pure (Commands.CommandIntent scope operation.operationId command)
              answer <- journal runtime "adaptive-dispatch" (liftIO (Commands.call runtime admission intent) >>= sessionResult)
              case answer of
                Left err -> pure (result fresh state "Refused" (Just (Text.pack (show err))))
                Right _ -> do
                  let reference = SessionReference key worker.sessionId scope initialRevision
                      sessions = if any ((== worker.sessionId) . (.sessionId)) next.sessions then next.sessions else next.sessions <> [reference]
                      models = case operation.change of P.EscalateModel _ alias -> (key, alias) : filter ((/= key) . fst) next.modelSelections; P.TransferAssignment {} -> filter ((/= key) . fst) next.modelSelections; _ -> next.modelSelections
                  let transfer = case operation.change of P.TransferAssignment {} -> Just (TransferReference key worker.sessionId scope operation.operationId); _ -> next.transfer
                  rotate (next & #sessions .~ sessions & #modelSelections .~ models & #transfer .~ transfer)
            _ -> throwIO (userError "adaptive find returned the wrong command result")

provided :: P.Change -> Maybe Workers.WorkerInstruction
provided = \case P.DirectWork _ input -> Just input; P.FollowUpContext _ input -> Just input; _ -> Nothing

selected :: Seed -> ObjectiveAssignmentId -> P.Change -> Maybe ModelAlias
selected seed key = \case P.EscalateModel _ alias -> Just alias; _ -> lookup key seed.modelSelections

direct :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> Seed -> P.AcceptedDecision -> P.ExecutableOperation -> P.Placement -> Assignment -> Eff (Workflow : AppEffects) DeliveryResult
direct runtime admission checkpoint state next _decision operation placement assignment = do
  input <- require (Commands.instruction checkpoint.objective assignment (provided operation.change) (selected state assignment.definition.assignmentId operation.change))
  accepted <- journal runtime "adaptive-direct-admit" (liftIO (Direct.admit runtime admission checkpoint placement operation.operationId input))
  start <- either (\err -> throwIO (DecisionAbort (decisionFailure EvidenceFailure (Text.pack (show err))))) pure accepted
  completed <- Execution.requestExecution runtime.execution start
  retained <- journal runtime "adaptive-direct-result" $ do
    value <- liftIO (Execution.readExecutionResult runtime.execution admission.run.identity completed)
    either (\err -> throwIO (DecisionAbort (decisionFailure EvidenceFailure (Text.pack (show err))))) (const (pure ())) value
    case completed.result of
      Just payload | completed.phase == Succeeded -> pure (DirectResult assignment.definition.assignmentId operation.operationId completed.executionId payload)
      _ -> throwIO (userError "direct work did not return an accepted result")
  advanced <- journal runtime "adaptive-direct-progress" $ liftIO $ Runtime.owned runtime (Owner.executeCommand (Runtime.host runtime admission) checkpoint.objective.objectiveId checkpoint.objective.revision (Runtime.operationKey "direct-progress" (toJSON operation.operationId)) (RecordProgress assignment.definition.assignmentId Done [] []))
  case advanced of
    Left ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "direct result progress acknowledgement unavailable")
    Left err -> pure (result checkpoint state "Refused" (Just (Text.pack (show err))))
    Right _ -> rotate (next & #directResults %~ (<> [retained]) & #reflect .~ True)

waitForCheckpoint :: Runtime.Runtime -> Admission -> Checkpoint -> Seed -> Eff (Workflow : AppEffects) DeliveryResult
waitForCheckpoint runtime admission checkpoint state = do
  (token, await) <- Generated.allocateDeclaredAwait Generated.checkpointChangeAwait
  (name, owner) <- currentWorkflow
  generation <- currentRunGeneration
  let listener = Wake.Listener checkpoint.objective.objectiveId name owner generation token checkpoint.objective.revision
  subscribed <- journal runtime "adaptive-subscribe" $ do
    liftIO (Runtime.validateAdmission runtime admission) >>= require
    nativeGeneration <- either (throwIO . userError . Text.unpack) pure (Input.parseWorkflowGeneration generation)
    forM_ state.sessions \reference -> do
      let native = Session.CheckpointSessionListener token nativeGeneration name owner reference.after
          operation = Runtime.operationKey "subscribe" (toJSON (owner.unWorkflowId, generation, reference.sessionId, reference.after))
      subscription <- liftIO (Commands.subscribe runtime admission reference operation native)
      case subscription of
        Right () -> pure ()
        Left Session.SessionStorageUnavailable -> throwIO (TransientBehaviorFailure "adaptive native event subscription unavailable")
        Left err -> throwIO (DecisionAbort (decisionFailure EvidenceFailure (Text.pack (show err))))
    Wake.validateListener listener >>= require
    notify <- Wake.prepareListener listener
    now <- liftIO getCurrentTime
    access <- liftIO (Owner.admitObjectiveAction (Runtime.host runtime admission) "adaptive-subscribe" (toJSON listener)) >>= require
    Goals.coordinationQuery
      access
      checkpoint.objective.objectiveId
      ( \goal ->
          if Goals.mayCoordinate access goal
            then do
              registered <- Wake.registerTx listener goal.revision notify
              case registered of
                Right () -> do
                  void (scheduleTimerOnceTx (Wake.cutoffRequest listener admission.organization.cutoff))
                  when (isJust state.transfer) (void (scheduleTimerOnceTx (Wake.recheckRequest listener now)))
                _ -> pure ()
              pure registered
            else pure (Left ObjectiveDenied)
      )
      <&> (>>= id)
  case subscribed of
    Left ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "adaptive checkpoint subscription unavailable")
    Left err -> void (cancelAwakeable token) >> pure (result checkpoint state "Refused" (Just (Text.pack (show err))))
    Right () -> do
      _ <- await :: Eff (Workflow : AppEffects) Bool
      rotate state

vocabulary :: Value
vocabulary =
  object
    [ "proposal" .= ("Copy proposalCoordinates, add evidence:[existing evidence keys], rationale, friction:null|text, expectedBenefit, laterEvidence, changes:[closed changes]. No extra fields." :: Text),
      "changes" .= ("A change is {tag,contents}. CreateAssignment contents={assignment:{assignmentId,instructions,dependencies,owner,state:Pending,sessionId:null,rootId,cutoff},target,parent:null|assignmentId}; NarrowAssignment contents=[assignmentId,instructions]; SplitAssignment contents=[assignmentId,[placements]]; ConsolidateAssignments contents=[[assignmentIds],placement]; FollowUpContext or DirectWork contents=[assignmentId,{text,objectiveRevision,assignmentRevision,criteriaRevision,selection:null|{alias,permittedAliases,thinking:null}}]; TransferAssignment contents=[assignmentId,target,pinnedWorkspace]; EscalateModel contents=[assignmentId,alias]; ChangeConcurrency contents=positive integer; IntegrateResult contents=[assignmentId,exact evidence input]; AwaitAssignments contents=[assignmentIds]; ProposeCompletion contents={objectiveRevision,instructionsRevision,criteriaRevision,artifacts,checks,limitations}. Select only names, principals, model aliases and workspace references supplied by the checkpoint/pinned policy." :: Text)
    ]
