{-# LANGUAGE DataKinds #-}

-- | Dedicated objective commands over a frozen admission. Model arguments have
-- no actor, resource root, scope grant or new durable operation key.
module Shikigami.Objective.Tools (Input (..), AssignmentInput (..), objectiveTools, inputSchema) where

import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Coordinate
import Shikigami.Execution.Executor (BoundTool (..))
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Execution.Policy.Types (RecoveryClass (IdempotentEffect), ToolInvoiceCost (NoInvoiceCost))
import Shikigami.Execution.Resources (AttemptRequest (..))
import Shikigami.Execution.Runner (OperationContext (..), PreparedTool (..), ToolPreparation (..))
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Tools (NativeToolFactory (..))
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Origin qualified as Origin
import Shikigami.Objective.Runtime qualified as Runtime
import Shikigami.Objective.Schema qualified as Schema
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Shikumi.Tool (SomeTool (..), ToolError (..))
import Shikumi.Tool.Output (ToolOutput (..), textToolOutput)

-- A creator plans assignments for its own recorded principal. Root and cutoff
-- come from the original resource owner; no model field can replace them.
data AssignmentInput = AssignmentInput {assignmentId :: !ObjectiveAssignmentId, instructions :: !Instructions, dependencies :: ![ObjectiveAssignmentId], state :: !AssignmentState}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON AssignmentInput where parseJSON = Aeson.genericParseJSON (defaultOptions {rejectUnknownFields = True})

instance Show AssignmentInput where show _ = "ObjectiveAssignmentInput <protected>"

data Input
  = CreateObjective {request :: !CreateRequest}
  | InspectObjective {objectiveId :: !ObjectiveId, after :: !Int, limit :: !Int}
  | PlanAssignments {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), assignments :: ![AssignmentInput]}
  | RecordProgress {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), assignmentId :: !ObjectiveAssignmentId, state :: !AssignmentState, decisions :: ![DecisionNote], assumptions :: ![AssumptionNote]}
  | RecordEvidence {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), assignmentId :: !ObjectiveAssignmentId, evidence :: !EvidenceInput}
  | SetNextAction {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), nextActions :: ![NextAction]}
  | SetBlocked {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), blocked :: !BlockState}
  | ProposeCompletion {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective"), proposal :: !CompletionProposal}
  | AcceptCompletion {objectiveId :: !ObjectiveId, expectedRevision :: !(StateRevision "objective")}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Input where parseJSON = Aeson.genericParseJSON (defaultOptions {rejectUnknownFields = True})

instance Show Input where show _ = "ObjectiveInput <protected>"

objectiveTools :: Maybe Runtime.ObjectiveRuntime -> NativeToolFactory
objectiveTools configured = NativeToolFactory describe prepare
  where
    describe snapshot = case snapshot.objectiveScope of
      Nothing -> pure (Right [])
      Just scope -> case configured of
        Nothing -> pure (Left (Replay.ExecutionPolicyRefused "objective authority unavailable"))
        Just runtime -> do
          checked <- Runtime.validateRetainedScope runtime scope
          pure (either (const (Left (Replay.ExecutionPolicyRefused "objective scope unavailable"))) (const (Right [bound runtime scope Nothing])) checked)
    prepare snapshot context requested
      | maybe False (/= executionCoordinate "objectives") requested = pure (Right [])
      | otherwise = case filter ((== executionCoordinate "objectives") . (.name)) snapshot.toolBindings of
          [] -> pure (Right [])
          [binding] -> case (configured, snapshot.objectiveScope) of
            (Just runtime, Just scope)
              | binding == bindingFor scope && Scope.matchesExecution scope snapshot.runId snapshot.identity snapshot.sessionId snapshot.selection.rootId snapshot.selection.permittedAliases snapshot.selection.assignmentId -> do
                  valid <- Runtime.validateRetainedScope runtime scope
                  case valid of
                    Left ObjectiveUnavailable -> unavailable
                    Left _ -> pure (Left (Replay.ExecutionPolicyRefused "objective scope unavailable"))
                    Right () -> do
                      source <- sourceFor runtime snapshot scope context
                      pure (fmap (\accepted -> [bound runtime scope (Just (context, accepted))]) source)
            _ -> pure (Left (Replay.ExecutionPolicyRefused "objective binding differs from retained scope"))
          _ -> pure (Left (Replay.ExecutionPolicyRefused "ambiguous objective binding"))
    unavailable = throwIO (TransientBehaviorFailure "objective preparation is unavailable")
    bound :: Runtime.ObjectiveRuntime -> Scope.ObjectiveScope -> Maybe (OperationContext, (Origin.OriginAuthority, Aeson.Value, Replay.NextWork)) -> BoundTool
    bound runtime scope accepted = BoundTool (bindingFor scope) $
      DynTool "objectives" "Read current objective progress, create a permitted objective, plan your own assignments, record evidence or propose completion. Runtime supplies authority and operation identity; returned references confer no authority." (inputSchema scope) \arguments -> case (accepted, Aeson.fromJSON arguments) of
        (Nothing, _) -> pure (Left (ToolRunFailed "objectives" "description cannot execute objective work"))
        (_, Aeson.Error _) -> pure (Left (ToolArgsInvalid "objectives" "invalid closed objective command"))
        (Just (_, (_, original, _)), _) | arguments /= original -> pure (Left (ToolArgsInvalid "objectives" "arguments differ from the accepted operation"))
        (Just (context, (origin, _, next)), Aeson.Success input) -> do
          result <- unsafeEff_ (invoke runtime scope origin context.operationId input >>= Operation.requireResolved)
          let value = toJSON result
              output = (textToolOutput (Text.decodeUtf8 (Lazy.toStrict (Aeson.encode value)))) {structuredContent = Just value}
          unsafeEff_ (acknowledgeCommandReceipt runtime scope context next result output)
          pure (Right output)

bindingFor :: Scope.ObjectiveScope -> Replay.ToolBinding
bindingFor scope = Replay.ToolBinding (executionCoordinate "objectives") (executionCoordinate ("objective-scope/1:" <> executionDigestText (Scope.scopeFingerprint scope))) (executionDigestFor "shikigami.tool-schema/1" (inputSchema scope)) IdempotentEffect NoInvoiceCost

-- Authenticate every OperationContext coordinate against the execution owner,
-- and retain the exact accepted arguments rather than trusting a callback value.
sourceFor :: Runtime.ObjectiveRuntime -> Replay.ExecutionSnapshot -> Scope.ObjectiveScope -> OperationContext -> IO (Either Replay.ExecutionError (Origin.OriginAuthority, Aeson.Value, Replay.NextWork))
sourceFor runtime snapshot scope context = do
  prepared <- execute do
    authorized <- Execution.authorizeReplay snapshot.executionId snapshot.identity (Directory.identityLifecycleAdmission runtime.directory snapshot.identity)
    case authorized of
      Left err -> pure (Left err)
      Right access -> do
        original <- Execution.loadExecution access
        now <- liftIO getCurrentTime
        case original of
          Right (actual, _) | actual == snapshot -> do
            checked <- Runner.prepareAcceptedTool now False Nothing access context.operationId snapshot.toolBindings (const (pure (Right ())))
            case checked of
              Right (ToolReady request) | request.context == context -> do
                response <- Execution.readReplayPayload @Replay.OperationOutcome access "operation-outcome" request.input.response
                pure case response of
                  Right (Replay.ModelReturned assistant _) -> Right (access, request.input.invocation.arguments, Replay.toolContinuation request.input assistant)
                  Left err -> Left err
                  _ -> Left Replay.CorruptReplay
              Left err -> pure (Left err)
              _ -> pure (Left Replay.OperationConflict)
          _ -> pure (Left Replay.CorruptReplay)
  case prepared of
    Left Replay.ExecutionStorageUnavailable -> unavailable
    Left Replay.ProjectionUnavailable -> unavailable
    Left err -> pure (Left err)
    Right (access, arguments, next) -> do
      source <- Runtime.owned runtime case scope.source of
        Scope.AgentScope _ -> Origin.executionAuthority access context.operationId
        Scope.ConversationScope _ conversation turn -> Origin.conversationAuthority (Runtime.hostFor runtime scope.identity) access conversation turn context.operationId
        Scope.FlowScope {} -> pure (Left ObjectiveDenied)
      case source of
        Left ObjectiveUnavailable -> unavailable
        Left _ -> pure (Left (Replay.ExecutionPolicyRefused "objective origin unavailable"))
        Right origin -> pure (Right (origin, arguments, next))
  where
    execute :: Eff AppEffects (Either Replay.ExecutionError a) -> IO (Either Replay.ExecutionError a)
    execute action = runAppIO runtime.appEnv action <&> either (const (Left Replay.ExecutionStorageUnavailable)) id
    unavailable = throwIO (TransientBehaviorFailure "objective operation source is unavailable")

-- A positive command receipt is the independent factual owner's immutable
-- result for this exact accepted operation. The revision-1 renderer reproduces
-- its original rich output; no socket/model body supplies an acknowledgement.
-- Mutable inspections have no such receipt and must retain their uncertainty.
acknowledgeCommandReceipt :: Runtime.ObjectiveRuntime -> Scope.ObjectiveScope -> OperationContext -> Replay.NextWork -> Either ObjectiveError Operation.Reply -> ToolOutput -> IO ()
acknowledgeCommandReceipt runtime scope context next result output = case committed of
  Nothing -> pure ()
  Just receipt | receipt.operationId == context.operationId -> do
    acknowledged <- runAppIO runtime.appEnv do
      attempts <- Execution.inspectOperationAttempts context.operationId
      case attempts of
        Left err -> pure (Left err)
        Right stored -> settleAll [attempt | attempt <- stored, attempt.phase == Attempt.AttemptSuperseded, isNothing attempt.lateReceipt]
    case acknowledged of
      Right (Right ()) -> pure ()
      _ -> throwIO (TransientBehaviorFailure "objective receipt acknowledgement is unavailable")
  _ -> throwIO (TransientBehaviorFailure "objective receipt differs from its accepted operation")
  where
    committed = case result of
      Right Operation.Reply {result = Operation.ObjectiveCreated receipt} -> Just receipt
      Right Operation.Reply {result = Operation.ObjectiveUpdated receipt} -> Just receipt
      _ -> Nothing
    factual = Attempt.AttemptResult (Replay.RichToolReturned (Replay.captureToolOutput output)) next Nothing
    settleAll [] = pure (Right ())
    settleAll (attempt : remaining) = case attempt.owner of
      Nothing -> pure (Left Replay.AttemptClaimLost)
      Just owner -> do
        let reference = Attempt.JobReference V1 context.executionId context.operationId attempt.request.attemptId
            claim = Attempt.AttemptClaim reference owner attempt.generation
        settled <- settle claim (3 :: Int)
        case settled of Left err -> pure (Left err); Right () -> settleAll remaining
    settle _ 0 = pure (Left Replay.ExecutionRevisionConflict)
    settle claim remaining = do
      current <- Execution.inspectExecution context.executionId
      case current of
        Right (Just (state, _, _)) ->
          Execution.recordIndependentToolReceipt scope.identity state.revision claim factual >>= \case
            Right _ -> pure (Right ())
            Left Replay.ExecutionRevisionConflict -> settle claim (remaining - 1)
            Left err -> pure (Left err)
        Right Nothing -> pure (Left Replay.ExecutionMissing)
        Left err -> pure (Left err)

invoke :: Runtime.ObjectiveRuntime -> Scope.ObjectiveScope -> Origin.OriginAuthority -> OperationId -> Input -> IO (Either ObjectiveError Operation.Reply)
invoke runtime scope origin operation input = do
  converted <- case input of
    CreateObjective body -> pure (Right (Operation.CreateObjective body))
    InspectObjective objective after limit -> pure (Right (Operation.InspectObjective objective after limit))
    PlanAssignments objective expected inputs -> do
      let drafts = [AssignmentDraft value.assignmentId value.instructions value.dependencies scope.identity value.state Nothing scope.rootId scope.cutoff | value <- inputs]
      pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.SetAssignments drafts)))
    RecordProgress objective expected assignment state decisions assumptions -> pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.RecordProgress assignment state decisions assumptions)))
    RecordEvidence objective expected assignment evidence -> pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.RecordEvidence assignment evidence)))
    SetNextAction objective expected next -> pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.SetNextAction next)))
    SetBlocked objective expected blocked -> pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.SetBlocked blocked)))
    ProposeCompletion objective expected proposal -> pure (Right (Operation.ApplyObjectiveCommand objective expected (Command.ProposeCompletion proposal)))
    AcceptCompletion objective expected -> pure (Right (Operation.ApplyObjectiveCommand objective expected Command.AcceptCompletion))
  case converted of
    Left err -> pure (Left err)
    Right request -> Operation.execute runtime scope origin operation request

inputSchema :: Scope.ObjectiveScope -> Aeson.Value
inputSchema scope =
  Schema.oneOfSchema
    ( [Schema.objectSchema [("tag", Schema.constant "CreateObjective"), ("request", Schema.createRequestSchema)] | Scope.CreateObjectives `elem` scope.permissions]
        <> [ Schema.objectSchema [("tag", Schema.constant "InspectObjective"), ("objectiveId", Schema.stringSchema), ("after", Schema.integerSchema), ("limit", Schema.integerSchema)],
             command "PlanAssignments" [("assignments", Schema.arraySchema (Schema.objectSchema [("assignmentId", Schema.assignmentKeySchema), ("instructions", Schema.stringSchema), ("dependencies", Schema.arraySchema Schema.assignmentKeySchema), ("state", state)]))],
             command "RecordProgress" [("assignmentId", Schema.assignmentKeySchema), ("state", state), ("decisions", Schema.arraySchema Schema.stringSchema), ("assumptions", Schema.arraySchema Schema.stringSchema)],
             command "RecordEvidence" [("assignmentId", Schema.assignmentKeySchema), ("evidence", Schema.evidenceSchema)],
             command "SetNextAction" [("nextActions", Schema.arraySchema Schema.stringSchema)],
             command "SetBlocked" [("blocked", Schema.boolSchema)],
             command "ProposeCompletion" [("proposal", Schema.proposalSchema)],
             command "AcceptCompletion" []
           ]
    )
  where
    command tag fields = Schema.objectSchema ([("tag", Schema.constant tag), ("objectiveId", Schema.stringSchema), ("expectedRevision", Schema.integerSchema)] <> fields)
    state = Schema.enumSchema ["Pending", "Working", "Done", "Withdrawn"]
