-- Native continuing-session gates use the real objective owner and workspace
-- supervisor. Only the model responses and ownership acknowledgement loss are
-- injected; fence and ownership receipts come from their production owners.
module Continuing (continuingCase) where

import Accepted
import Control.Monad (unless, void, when)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import FixtureIdentity (fixtureOperationId, fixtureRootId)
import GHC.Generics (Generic)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Qualification
import Shikigami.Agent.Decl (defaultDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Capability qualified as Objectives
import Shikigami.Objective.Checkpoint (checkpointProvider)
import Shikigami.Objective.Command qualified as Goal
import Shikigami.Objective.Ownership (ownershipProvider)
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types qualified as Goal
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.StateRevision (StateRevision, advanceRevision, parseRevision)
import Shikigami.WorkerSession.Checkpoint (CheckpointProvider (..), ObjectiveVersion (..))
import Shikigami.WorkerSession.Handoff qualified as Handoff
import Shikigami.WorkerSession.Input (InstructionText, SessionLimit (..), parseInstructionText)
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Cleanup
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferClient
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))

data Continuing = Continuing {binding :: !WorkspaceBinding, admission :: !WorkspaceAdmission, prepared :: !Prepared, session :: !WorkerSessionId, actor :: !AgentIdentity}
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

continuingCase :: FilePath -> FilePath -> String -> IO ()
continuingCase config prefix stage = withQualification config prefix \q -> case stage of
  "followup" -> followup q
  "prepare" -> do
    (session, actor, runId, root) <- openNativeSession q "handoff"
    admission <- loadAssignment q root runId q.initial.binding.request.owner
    first <- prepareTools q.env q.authorizer q.current q.client admission [edit "src/dependency.txt" "old dependency\n" "new dependency\n", edit "src/mode" "complete\n" "orphan\n", validate]
    executeConfigured q first
    Just second <- advanceTools q.env q.current first
    executeConfigured q second
    Just process <- advanceTools q.env q.current second
    Just (binding, _) <- right =<< run q.env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
    Lazy.writeFile (prefix </> "continuing.json") (Aeson.encode (Continuing binding admission process session actor))
  "worker" -> withCase q \item -> executeConfigured q item.prepared
  "inspect" -> withCase q \item -> do
    process <- right =<< run q.env (runTransaction (Processes.inspectProcessTx item.prepared.reference.operationId))
    actual <- right =<< run q.env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
    let capture record = "shikigami-capture-" <> Text.drop (Text.length ("shikigami-workspace-" :: Text.Text)) (workspaceCoordinateText record.unit)
    Lazy.writeFile (prefix </> "continuing-status.json") (Aeson.encode (Aeson.object ["process" Aeson..= process, "actual" Aeson..= actual, "capture" Aeson..= (capture <$> process), "files" Aeson..= workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding]))
  "freeze" -> withCase q \item -> do
    access <- sessionAccess q item
    Just (state, _) <- right =<< run q.env (Sessions.inspectSession item.session)
    successor <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_01h000000000000000successor")
    Just (_, binding) <- right =<< run q.env (Sessions.inspectSession item.session)
    expected <- right =<< (checkpointProvider q.env item.actor (q.objectives item.actor)).current binding.objective
    (_, intent) <- right =<< run q.env (Sessions.requestTransfer access state.revision (fixtureRevision 0) (fixtureOperationId "native-freeze") expected item.binding.workspace (fixtureAgentName "successor") successor)
    Lazy.writeFile (prefix </> "continuing-intent.json") (Aeson.encode intent)
    outcome <- (workspaceTransferClient q.client).reconcile intent
    unless (outcome == FenceUnresolved) (fail "held collector unexpectedly established a fence")
    refused =<< (workspaceTransferClient q.client).admitWrite item.binding.workspace item.session successor (fixtureRevision 1) (fixtureOperationId "premature-successor-write")
    putStrLn "PASS a real in-flight descendant and held collector keep the transfer fence unresolved"
  "settled" -> withCase q \item -> do
    intent <- right . Aeson.eitherDecodeStrict @TransferIntent =<< Bytes.readFile (prefix </> "continuing-intent.json")
    outcome <- (workspaceTransferClient q.client).reconcile intent
    proof <- case outcome of FencedAndSettled value -> pure value; _ -> fail "restarted fence is not settled"
    unless (matchesFence intent proof) (fail "fence coordinates changed")
    again <- (workspaceTransferClient q.client).reconcile intent
    unless (again == outcome) (fail "duplicate fence differs")
    Just process <- right =<< run q.env (runTransaction (Processes.inspectProcessTx item.prepared.reference.operationId))
    receipt <- maybe (fail "native settlement receipt absent") pure process.receipt
    unless (process.phase == ProcessSettled && descendantsSettled receipt.descendantsEmpty && outputCollected receipt.outputComplete) (fail "descendant settlement is not factual")
    Just actual <- right =<< run q.env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
    unless (process.attemptId == actual.request.attemptId && process.generation == actual.generation && (actual.phase == Attempt.AttemptCommitted || maybe False (const True) actual.lateReceipt)) (fail "original actual was not recovered")
    launchCount <- Bytes.readFile (workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding </> "src/launch-count")
    unless (launchCount == "1") (fail "handoff relaunched command")
    original <- Bytes.readFile (workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding </> "src/dependency.txt")
    unless (original == "new dependency\n") (fail "accepted files were lost")
    Lazy.writeFile (prefix </> "continuing-evidence.json") (Aeson.encode (Aeson.object ["fence" Aeson..= proof, "receipt" Aeson..= receipt]))
    putStrLn "PASS provider restart recovers the original actual and exact settled fence after authority denial"
  "late" -> withCase q \item -> do
    let provider = workspaceTransferClient q.client
    refused =<< provider.admitWrite item.binding.workspace item.session item.admission.owner item.admission.epoch (fixtureOperationId "late-old-owner-write")
    intent <- right . Aeson.eitherDecodeStrict @TransferIntent =<< Bytes.readFile (prefix </> "continuing-intent.json")
    refused =<< provider.admitWrite item.binding.workspace item.session intent.newOwner intent.newEpoch (fixtureOperationId "unestablished-owner-write")
    late <- continueTools q.env q.current item.prepared [edit "src/dependency.txt" "new dependency\n" "LATE_OLD_OWNER_WRITE\n"]
    executeConfigured q late
    access <- right =<< run q.env (Execution.authorizeReplay late.snapshot.executionId late.snapshot.identity (q.current late.snapshot))
    Just operation <- right =<< run q.env (Execution.inspectOperation late.reference.operationId)
    result <- maybe (fail "late old-owner outcome absent") pure operation.outcome
    outcome <- right =<< run q.env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
    unless (case outcome of ToolReturned _ ToolFailed -> True; RichToolReturned output -> toolFailed output.failed; _ -> False) (fail "late old-owner accepted edit succeeded")
    retained <- Bytes.readFile (workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding </> "src/dependency.txt")
    unless (retained == "new dependency\n") (fail "late old-owner edit changed accepted bytes")
    putStrLn "PASS a real accepted late old-owner edit and unestablished successor admission both refuse under fresh authority"
  "ownership" -> withCase q \item -> do
    -- Commit through the real objective owner, then lose only its response.
    -- The next controller process must recover that exact receipt.
    terminal q item.prepared
    access <- sessionAccess q item
    Just (state, _) <- right =<< run q.env (Sessions.inspectSession item.session)
    original <- maybe (fail "handoff assignment absent") pure state.activeAssignment
    void (right =<< run q.env (Sessions.recordResult access state.revision state.epoch (fixtureOperationId "handoff-original-result") (AssignmentResult V1 original AssignmentFailed (Just item.prepared.snapshot.executionId) Aeson.Null [])))
    let services = transferServices q item
        owner = maybe (error "real owner absent") id services.ownership
        lossy = OwnershipProvider \intent proof ->
          owner.transfer intent proof >>= \case
            OwnershipAccepted _ -> pure OwnershipUnresolved
            other -> pure other
    outcome <- right =<< run q.env (Handoff.resumeHandoff (services & #ownership .~ Just lossy) item.session)
    unless (outcome == Handoff.HandoffPending) (fail "ownership loss did not leave handoff pending")
    Just (pending, binding) <- right =<< run q.env (Sessions.inspectSession item.session)
    objective <- right =<< run q.env (Objectives.resolveAssignment (q.objectives item.actor) binding.objective)
    goal <- right =<< run q.env (Objectives.readObjective (q.objectives item.actor) objective.objectiveId)
    addressed <- maybe (fail "real assignment absent") pure (find ((== objective.assignmentId) . (.definition.assignmentId)) goal.assignments)
    unless (pending.owner == item.admission.owner && addressed.definition.owner /= pending.owner && addressed.ownerEpoch == advanceRevision pending.epoch) (fail "objective receipt did not commit before local establishment")
    Lazy.writeFile (prefix </> "continuing-ownership.json") (Aeson.encode (Aeson.object ["objective" Aeson..= objective.objectiveId, "assignment" Aeson..= addressed, "revision" Aeson..= goal.revision, "sessionOwner" Aeson..= pending.owner, "sessionEpoch" Aeson..= pending.epoch]))
    putStrLn "PASS real objective ownership commits once while acknowledgement loss leaves the local session frozen"
  "successor" -> withCase q \item -> do
    intent <- right . Aeson.eitherDecodeStrict @TransferIntent =<< Bytes.readFile (prefix </> "continuing-intent.json")
    outcome <- right =<< run q.env (Handoff.resumeHandoff (transferServices q item) item.session)
    unless (outcome == Handoff.HandoffEstablished intent.newOwner intent.newEpoch) (fail "real ownership recovery did not establish successor")
    repeated <- right =<< run q.env (Handoff.resumeHandoff (transferServices q item) item.session)
    unless (repeated == outcome) (fail "duplicate ownership recovery differs")
    access <- sessionAccess q item
    Just (state, binding) <- right =<< run q.env (Sessions.inspectSession item.session)
    expected <- right =<< (checkpointProvider q.env item.actor (q.objectives item.actor)).current binding.objective
    (_, message) <- right =<< run q.env (Sessions.acceptMessage access state.revision state.epoch (fixtureOperationId "native-successor-message") (Instruction V1 FollowUp (fixtureInstruction "continue fenced workspace") expected.revision expected.assignmentRevision expected.criteriaRevision Nothing))
    (_, started) <- right =<< run q.env (Sessions.startAssignment access (advanceRevision state.revision) state.epoch (fixtureOperationId "native-successor-start") message.assignmentId)
    child <- maybe (fail "successor child absent") (pure . (.unWorkflowId)) started.childWorkflowId
    next <- loadAssignment q item.admission.rootId child intent.newOwner
    unless (next.workspace == item.admission.workspace && next.bindingDigest == item.admission.bindingDigest && next.instructions == item.admission.instructions && next.epoch == intent.newEpoch) (fail "successor changed allocation or frozen instructions")
    profile <- right =<< run q.env (runTransaction (inspectProcessProfileTx next.workspace))
    prepared <- prepareTools q.env q.authorizer q.current q.client next [edit "src/integration-c" "0\n" "2\n", edit "src/mode" "orphan\n" "complete\n", validate]
    (lastTool, _) <- runTools q prepared
    after <- right =<< run q.env (runTransaction (inspectProcessProfileTx next.workspace))
    unless (profile == after) (fail "successor changed ready Unix profile")
    bytes <- Bytes.readFile (workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding </> "src/integration-c")
    unless (bytes == "2\n") (fail "accepted successor write did not publish")
    Just process <- right =<< run q.env (runTransaction (Processes.inspectProcessTx lastTool.reference.operationId))
    unless (maybe False (\receipt -> receipt.termination == ProcessExited && fmap processExitStatusNumber receipt.exitCode == Just 0 && descendantsSettled receipt.descendantsEmpty) process.receipt) (fail "successor validation failed")
    Lazy.writeFile (prefix </> "continuing-successor.json") (Aeson.encode (Aeson.object ["admission" Aeson..= next, "profile" Aeson..= fmap (\(p, _) -> p) profile, "process" Aeson..= process, "handoff" Aeson..= outcome]))
    putStrLn "PASS restarted real ownership recovery admits an accepted successor write and native validation in the original workspace"
  _ -> fail "unsupported continuing fixture stage"
  where
    withCase _ use = (right . Aeson.eitherDecodeStrict @Continuing =<< Bytes.readFile (prefix </> "continuing.json")) >>= use
    refused (Left _) = pure ()
    refused (Right ()) = fail "unsafe continuing write admission"

followup :: Qualification -> IO ()
followup q = do
  (session, actor, firstRun, root) <- openNativeSession q "followup"
  original <- loadAssignment q root firstRun q.initial.binding.request.owner
  first <- prepareTools q.env q.authorizer q.current q.client original [edit "src/dependency.txt" "old dependency\n" "new dependency\n", edit "src/integration-c" "0\n" "1\n", validate]
  (firstLast, _) <- runTools q first
  terminal q firstLast
  access <- right =<< run q.env (Sessions.authorizeSession session actor (q.lifecycle actor))
  Just (active, _) <- right =<< run q.env (Sessions.inspectSession session)
  originalAssignment <- maybe (fail "original assignment absent") pure active.activeAssignment
  void (right =<< run q.env (Sessions.recordResult access active.revision (fixtureRevision 0) (fixtureOperationId "followup-original-result") (AssignmentResult V1 originalAssignment AssignmentFailed (Just first.snapshot.executionId) Aeson.Null [])))
  Just (idle, _) <- right =<< run q.env (Sessions.inspectSession session)
  (_, message) <- right =<< run q.env (Sessions.acceptMessage access idle.revision (fixtureRevision 0) (fixtureOperationId "followup-next-message") (Instruction V1 FollowUp (fixtureInstruction "continue accepted repository") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
  (_, started) <- right =<< run q.env (Sessions.startAssignment access (advanceRevision idle.revision) (fixtureRevision 0) (fixtureOperationId "followup-next-start") message.assignmentId)
  nextRun <- maybe (fail "followup child absent") (pure . (.unWorkflowId)) started.childWorkflowId
  next <- loadAssignment q root nextRun original.owner
  unless (next.workspace == original.workspace && next.bindingDigest == original.bindingDigest && next.instructions == original.instructions && next.epoch == original.epoch) (fail "followup allocation or accepted instructions changed")
  Just (binding, _) <- right =<< run q.env (runTransaction (Store.inspectWorkspaceTx next.workspace))
  before <- right =<< run q.env (runTransaction (inspectProcessProfileTx binding.workspace))
  second <- prepareTools q.env q.authorizer q.current q.client next [edit "src/integration-c" "1\n" "2\n", validate]
  (secondLast, _) <- runTools q second
  after <- right =<< run q.env (runTransaction (inspectProcessProfileTx binding.workspace))
  unless (after == before) (fail "followup changed the ready Unix profile")
  terminal q secondLast
  Just (running, _) <- right =<< run q.env (Sessions.inspectSession session)
  void (right =<< run q.env (Sessions.recordResult access running.revision (fixtureRevision 0) (fixtureOperationId "followup-result") (AssignmentResult V1 message.assignmentId AssignmentFailed (Just second.snapshot.executionId) Aeson.Null [])))
  let maintenance = MaintenanceRuntime q.env binding.storageRoot q.authorizer q.lifecycle (pure ())
  retained <- cleanupWorkspace maintenance actor binding.workspace
  unless (retained == Left CleanupRefused) (fail "idle continuing session was cleaned")
  Just (finished, _) <- right =<< run q.env (Sessions.inspectSession session)
  void (right =<< run q.env (Sessions.closeSession access finished.revision (fixtureRevision 0) (fixtureOperationId "followup-close") AssignmentFailed))
  right =<< cleanupWorkspace maintenance actor binding.workspace
  right =<< cleanupWorkspace maintenance actor binding.workspace
  files <- doesDirectoryExist (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding)
  metadata <- doesDirectoryExist (workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding)
  unless (not files && metadata) (fail "terminal cleanup did not preserve metadata")
  putStrLn "PASS configured followup writes retain files, frozen instructions and Unix identity; idle retention and terminal cleanup converge"

terminal :: Qualification -> Prepared -> IO ()
terminal q prepared = do
  Just (state, _, _) <- right =<< run q.env (Execution.inspectExecution prepared.snapshot.executionId)
  -- This fixture drives accepted tool contracts, not a normal final model turn.
  -- Its explicit failed terminal is honest and leaves the shared root active.
  void (right =<< run q.env (Execution.stopExecution prepared.snapshot.identity prepared.snapshot.executionId state.revision StopAsFailure (ExecutionPolicyRefused "fixture tools completed")))

openNativeSession :: Qualification -> Text.Text -> IO (WorkerSessionId, AgentIdentity, Text.Text, ExecutionRootId)
openNativeSession q name = do
  now <- getCurrentTime
  parentMemory <- genSessionId
  original <- right =<< loadAgent "/var/lib/shikigami-workspace-fixture-code/agents/triage-note.dhall"
  actor <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_01h000000000000000coordinator")
  reference <- if name == "handoff" then seedObjective q actor q.initial.binding.request.owner (fixtureRootId ("continuing-" <> name <> "-root")) else pure (ObjectiveRef (workerCoordinate "uninstalled-objective-provider") (workerCoordinate name))
  let root = fixtureRootId ("continuing-" <> name <> "-root")
      owner = q.initial.binding.request.owner
      admission = SessionAdmission V1 (SessionScope (workerCoordinate ("native-" <> name)) (workerCoordinate "fixture")) reference (original & #name .~ fixtureAgentName "coordinator" & #delegates .~ map fixtureAgentName ["fixture", "successor"]) (DelegateCtx (fixtureDelegationDepth 0) actor (Just parentMemory) Nothing (Just (WorkflowId ("continuing-parent-" <> name))) [fixtureAgentName "coordinator"] Nothing (Just root) Nothing defaultDelegationBudget) (fixtureAgentName "fixture") owner (fixtureLimit 10) (fixtureLimit 4)
  void (right =<< run q.env Catalog.registerProjectionCatalog)
  void (right =<< run q.env (Roots.enrollRoot root (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
  void (right =<< run q.env (Sessions.openSession admission))
  when (name == "handoff") do
    target <- right =<< run q.env (Objectives.resolveAssignment (q.objectives actor) reference)
    objective <- right =<< run q.env (Objectives.readObjective (q.objectives actor) target.objectiveId)
    void (right =<< run q.env (Objectives.executeCommand (q.objectives actor) target.objectiveId objective.revision (fixtureOperationId "native-objective-session") (Goal.SetAssignments [a.definition & #sessionId .~ Just (sessionIdFor admission) & #rootId .~ Just root & #cutoff .~ Just (addUTCTime 3600 now) | a <- objective.assignments])))
  access <- right =<< run q.env (Sessions.authorizeSession (sessionIdFor admission) actor (q.lifecycle actor))
  (_, message) <- right =<< run q.env (Sessions.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId (name <> "-message")) (Instruction V1 FollowUp (fixtureInstruction "native workspace fixture") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
  (_, started) <- right =<< run q.env (Sessions.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId (name <> "-start")) message.assignmentId)
  child <- maybe (fail "native child absent") (pure . (.unWorkflowId)) started.childWorkflowId
  pure (sessionIdFor admission, actor, child, root)

seedObjective :: Qualification -> AgentIdentity -> AgentIdentity -> ExecutionRootId -> IO ObjectiveRef
seedObjective q actor owner _root = do
  operator <- right (Goal.parseOperatorId "native-fixture-operator")
  assignment <- right (Goal.parseObjectiveAssignmentId "workspace")
  instructions <- right (Goal.parseInstructions "continue governed repository work")
  title <- right (Goal.parseTitle "Native workspace handoff")
  goal <- right (Goal.parseGoal "transfer one fenced repository")
  key <- right (Goal.parseCriterionKey "fenced")
  description <- right (Goal.parseCriterionDescription "successor writes after fencing")
  let host = q.objectives actor & #settings . #operator .~ Just operator & #authenticate .~ pure (Right (Goal.LocalOperator operator))
  created <- right =<< run q.env (Objectives.createObjective host (fixtureOperationId "native-objective-create") Nothing (Goal.CreateRequest title goal instructions [Goal.Criterion key description Goal.HumanVerifiable Goal.JourneyOptional] []))
  void (right =<< run q.env (Objectives.executeCommand host created.objectiveId (fixtureRevision 0) (fixtureOperationId "native-objective-assign") (Goal.SetAssignments [Goal.AssignmentDraft assignment instructions [] owner Goal.Pending Nothing Nothing Nothing])))
  void (right =<< run q.env (Objectives.executeCommand host created.objectiveId (fixtureRevision 1) (fixtureOperationId "native-objective-grant") (Goal.GrantMember (Goal.RecordedAgent actor) [Goal.Coordinator])))
  pure (Goals.referenceFor created.objectiveId assignment)

transferServices :: Qualification -> Continuing -> Handoff.TransferServices
transferServices q item = Handoff.TransferServices sessions (Just workspace) (Just owner)
  where
    workspace = workspaceTransferClient q.client
    owner = ownershipProvider q.env item.actor (q.objectives item.actor) (Just workspace)
    sessions = SessionRuntime q.env [] disabledDirectoryHandle q.lifecycle (Just (\actor -> checkpointProvider q.env actor (q.objectives actor))) Nothing

sessionAccess :: Qualification -> Continuing -> IO Sessions.SessionAccess
sessionAccess q item = right =<< run q.env (Sessions.authorizeSession item.session item.actor (q.lifecycle item.actor))

edit :: Text.Text -> Text.Text -> Text.Text -> (Text.Text, Aeson.Value)
edit path before after = ("overlay__workspace-edit__replace", Aeson.toJSON (Replacement (workspaceCoordinate path) (Just (contentDigest before)) after))

validate :: (Text.Text, Aeson.Value)
validate = ("overlay__workspace-exec__validate", Aeson.object ["rule" Aeson..= ("validate" :: Text.Text)])

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text.Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureLimit :: (SessionLimit a) => Integer -> a
fixtureLimit value = either (error . show) id (parseSessionLimit value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger
