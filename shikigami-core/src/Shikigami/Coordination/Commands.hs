{-# LANGUAGE DataKinds #-}

-- | Stable accepted-manifest operations translated to the continuing-worker
-- command owner. The model supplies neither grants nor session identities.
module Shikigami.Coordination.Commands
  ( CommandIntent (..),
    operations,
    retainScope,
    call,
    subscribe,
    instruction,
    assignmentFor,
    ready,
    operationForAssignment,
  )
where

import Data.Generics.Labels ()
import Data.List (find)
import Effectful (Eff)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Coordination.Checkpoint (Checkpoint (..))
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Decision.Contract (ModelAlias)
import Shikigami.Execution.Coordinate (ExecutionDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Execution.Request (ExecutionRequest (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command (InternalCommand (RetainAdaptiveCoordination))
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime (ObjectiveRuntime (..))
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability qualified as Workers
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Types (SessionError (..), SessionListener, WorkerSessionId)

data CommandIntent = CommandIntent
  { scope :: !(ExecutionDigest "coordination-scope"),
    operationId :: !OperationId,
    command :: !Workers.WorkerCommand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Each new assignment receives a stable operation even when one graph change
-- creates several placements. One generation dispatches at most one command.
operations :: P.AcceptedDecision -> [P.ExecutableOperation]
operations decision = concatMap expand decision.operations
  where
    expand operation = case operation.change of
      P.SplitAssignment _ placements -> map (create operation) placements
      P.ConsolidateAssignments _ placement -> [create operation placement]
      _ -> [operation]
    create operation placement = P.ExecutableOperation (Runtime.operationKey "created-assignment" (toJSON (operation.operationId, placement.assignment.assignmentId))) (P.CreateAssignment placement)

assignmentFor :: Objective -> ObjectiveAssignmentId -> Either ObjectiveError Assignment
assignmentFor goal key = maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) goal.assignments)

ready :: Objective -> Assignment -> Bool
ready goal assignment = assignment.definition.state `notElem` [Done, Withdrawn] && all (\dependency -> any (\other -> other.definition.assignmentId == dependency && other.definition.state == Done) goal.assignments) assignment.definition.dependencies

operationForAssignment :: P.ExecutableOperation -> Maybe ObjectiveAssignmentId
operationForAssignment operation = case operation.change of
  P.CreateAssignment placement -> Just placement.assignment.assignmentId
  P.DirectWork key _ -> Just key
  P.FollowUpContext key _ -> Just key
  P.EscalateModel key _ -> Just key
  P.TransferAssignment key _ _ -> Just key
  _ -> Nothing

retainScope :: Runtime.Runtime -> Admission -> P.AcceptedDecision -> Checkpoint -> [SessionReference] -> IO (Either ObjectiveError (Maybe (ExecutionDigest "coordination-scope")))
retainScope runtime admission decision checkpoint known = do
  let goal = checkpoint.objective
      placements = [placement | placement <- checkpoint.arrangement, isNothing placement.parent, placement.target /= admission.organization.coordinator, placement.assignment.owner /= admission.run.identity, placement.assignment.state `notElem` [Done, Withdrawn]]
      slots = [Workers.WorkerSlot (Input.workerCoordinate (objectiveAssignmentIdText placement.assignment.assignmentId)) placement.target placement.assignment.owner (Goals.referenceFor goal.objectiveId placement.assignment.assignmentId) (placement.assignment.sessionId <|> ((.sessionId) <$> find ((== placement.assignment.assignmentId) . (.assignmentId)) known)) | placement <- placements]
      bounds = do
        maximumSessions <- Input.parseSessionLimit (toInteger admission.organization.maximumAssignments)
        maximumAssignments <- Input.parseSessionLimit (toInteger (max 1 admission.organization.maximumAssignments))
        mailbox <- Input.parseSessionLimit 4
        pure (Workers.PinnedCoordinationScope V1 admission.run (Goals.coordinatorParentScope goal.objectiveId admission.run.identity) admission.declaration admission.context slots maximumSessions maximumAssignments mailbox admission.declarations)
  if null slots
    then pure (Right Nothing)
    else case bounds of
      Left _ -> pure (Left ObjectiveDenied)
      Right scope -> do
        let operation = Runtime.operationKey "scope" (toJSON (decision.proposal.operationId, Workers.scopeFingerprint scope))
            command = RetainAdaptiveCoordination admission.objective.assignmentId admission.origin decision.proposal.operationId scope
            host =
              Runtime.host runtime admission
                & #verifyInternal
                .~ ( \actor actual ->
                       if actor == RecordedAgent admission.run.identity && actual == command
                         then
                           Runtime.validateAdmission runtime admission >>= \case
                             Left err -> pure (Left err)
                             Right () -> Runtime.fresh runtime admission
                         else pure (Left ObjectiveDenied)
                   )
        existing <- Runtime.owned runtime (Owner.lookupCoordinationScope host admission.run (Just (Workers.scopeFingerprint scope)))
        case existing of
          Right (Just retained) | retained == scope -> pure (Right (Just (Workers.scopeFingerprint scope)))
          Right Nothing -> do
            result <- Runtime.owned runtime (Owner.executeInternal host goal.objectiveId goal.revision operation command)
            pure (Just (Workers.scopeFingerprint scope) <$ result)
          Right _ -> pure (Left ObjectiveConflict)
          Left err -> pure (Left err)

call :: Runtime.Runtime -> Admission -> CommandIntent -> IO (Either SessionError Workers.WorkerReply)
call runtime admission intent = do
  result <- runAppIO runtime.objectives.appEnv $ do
    granted <- Workers.resolveGrant runtime.workers runtime.objectives.actions admission.run (Just intent.scope)
    case granted of
      Right (Just grant) -> Workers.executeCommand runtime.workers runtime.objectives.actions grant intent.operationId intent.command
      Right Nothing -> pure (Left SessionOwnerRefused)
      Left err -> pure (Left err)
  pure (either (const (Left SessionStorageUnavailable)) id result)

subscribe :: Runtime.Runtime -> Admission -> SessionReference -> OperationId -> SessionListener -> IO (Either SessionError ())
subscribe runtime admission reference operation listener = do
  result <- runAppIO runtime.objectives.appEnv do
    granted <- Workers.resolveGrant runtime.workers runtime.objectives.actions admission.run (Just reference.scope)
    case granted of
      Right (Just grant) -> void <$> Workers.subscribeCommand runtime.workers runtime.objectives.actions grant operation reference.sessionId listener
      Right Nothing -> pure (Left SessionOwnerRefused)
      Left err -> pure (Left err)
  pure (either (const (Left SessionStorageUnavailable)) id result)

-- The accepted text/selection stays fixed. Only trusted current checkpoint
-- coordinates are bound before this intent is journaled and dispatched.
instruction :: Objective -> Assignment -> Maybe Workers.WorkerInstruction -> Maybe ModelAlias -> Either ObjectiveError Workers.WorkerInstruction
instruction goal assignment supplied preferred = do
  text <- case supplied of
    Just input -> Right input.text
    Nothing -> either (const (Left (ObjectiveInvalid "assignment instruction is not a worker instruction"))) Right (Input.parseInstructionText (instructionsText assignment.definition.instructions))
  let selection = case supplied >>= (.selection) of
        Just selected -> Just selected
        Nothing -> (\alias -> ExecutionRequest (Just alias) (Just [alias]) Nothing) <$> preferred
  pure (Workers.WorkerInstruction text goal.revision assignment.revision goal.criteriaRevision selection)
