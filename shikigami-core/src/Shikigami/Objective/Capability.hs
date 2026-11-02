{-# LANGUAGE DataKinds #-}

-- | Authenticated admission for every objective adapter. Host callbacks consume
-- verified caller/runtime context; none is populated from command JSON.
module Shikigami.Objective.Capability
  ( ObjectiveHost (..),
    checkCreationAdmission,
    createObjective,
    createObjectiveWithDisposition,
    listObjectives,
    readHistory,
    readObjective,
    readObjectiveVersion,
    resolveAssignment,
    readCheckpointVersion,
    readInternalReceipt,
    lookupCoordinationScope,
    executeCommand,
    executeCommandWithTrackerCommit,
    admitObjectiveAction,
    executeInternal,
    readCommandReceipt,
    admitConversationTurn,
    readConversationTurn,
    lookupCreatedObjective,
    lookupCreatedInScope,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Coordinate (ExecutionDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Command
import Shikigami.Objective.Conversation qualified as Conversation
import Shikigami.Objective.Inspection (HistoryEntry)
import Shikigami.Objective.Reference (ObjectiveAssociation)
import Shikigami.Objective.Store qualified as Store
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability qualified as Coordination
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Types qualified as WS

data ObjectiveHost = ObjectiveHost
  { settings :: !ObjectiveSettings,
    authenticate :: !(IO (Either ObjectiveError AccessPrincipal)),
    actions :: !ActionAuthorizer,
    verifyOrigin :: !(AccessPrincipal -> CreationOrigin -> IO (Either ObjectiveError ())),
    verifyInternal :: !(AccessPrincipal -> InternalCommand -> IO (Either ObjectiveError ())),
    verifyResult :: !(ResultReference -> IO (Either ObjectiveError EvidenceVerification))
  }
  deriving stock (Generic)

admitObjectiveAction :: ObjectiveHost -> Text -> Aeson.Value -> IO (Either ObjectiveError Access)
admitObjectiveAction host label semantic = do
  attempted <- trySyncIO do
    authenticated <- host.authenticate
    case authenticated of
      Left err -> pure (Left err)
      Right actor | validPrincipal actor -> do
        exact <- case actor of
          RecordedAgent identity -> case (identityText identity, mkCapabilityToolTarget "shikigami.objectives" "1" (label <> "-" <> Text.replace ":" "-" (versionedDigest "shikigami.objective-action/1" semantic))) of
            (Right principal, Right target) -> host.actions.authorize (declarationCoordinate principal) (InvokeCapabilityTool target) <&> either (const (Left ObjectiveDenied)) (const (Right ()))
            _ -> pure (Left ObjectiveDenied)
          LocalOperator identity -> pure (if host.settings.operator == Just identity then Right () else Left ObjectiveDenied)
          VerifiedCaller _ -> pure (Right ())
        now <- getCurrentTime
        pure (Access actor host.settings (addUTCTime 30 now) [] Nothing <$ exact)
      Right _ -> pure (Left ObjectiveDenied)
  pure (either (const (Left ObjectiveUnavailable)) id attempted)

checkCreationAdmission :: (Store.ObjectiveEffects es) => ObjectiveHost -> Aeson.Value -> Eff es (Either ObjectiveError ())
checkCreationAdmission host source = do
  grant <- liftIO (admitObjectiveAction host "admit-creation-scope" source)
  either (pure . Left) Store.checkCreationAdmission grant

createObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> OperationId -> Maybe CreationOrigin -> CreateRequest -> Eff es (Either ObjectiveError Receipt)
createObjective host operation origin request = fmap (fmap snd) (createObjectiveWithDisposition host operation origin request)

createObjectiveWithDisposition :: (Store.ObjectiveEffects es) => ObjectiveHost -> OperationId -> Maybe CreationOrigin -> CreateRequest -> Eff es (Either ObjectiveError (Bool, Receipt))
createObjectiveWithDisposition host operation origin request = do
  grant <- liftIO (admitObjectiveAction host "create" (toJSON (operation, origin, request)))
  case grant of
    Left err -> pure (Left err)
    Right access -> do
      Store.createWithDisposition access operation origin request do
        verified <- trySyncIO do
          checked <- case origin of Nothing -> pure (Right ()); Just value -> host.verifyOrigin access.actor value
          fresh <- admitObjectiveAction host "create" (toJSON (operation, origin, request))
          pure (checked >> (fresh >>= \current -> if current.actor == access.actor then Right () else Left ObjectiveDenied))
        pure (either (const (Left ObjectiveUnavailable)) id verified)

listObjectives :: (Store.ObjectiveEffects es) => ObjectiveHost -> Maybe ObjectiveId -> Int -> Eff es (Either ObjectiveError [Objective])
listObjectives host after limit = do
  grant <- liftIO (admitObjectiveAction host "list" (toJSON (after, limit)))
  either (pure . Left) (\access -> Store.listObjectives access after limit) grant

readHistory :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> Maybe (StateRevision "objective") -> Int -> Eff es (Either ObjectiveError [HistoryEntry])
readHistory host objective after limit = do
  grant <- liftIO (admitObjectiveAction host "history" (toJSON (objective, after, limit)))
  either (pure . Left) (\access -> Store.history access objective after limit) grant

readObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> Eff es (Either ObjectiveError Objective)
readObjective host objective = do
  grant <- liftIO (admitObjectiveAction host "read" (toJSON objective))
  either (pure . Left) (\access -> Store.read access objective) grant

readObjectiveVersion :: (Store.ObjectiveEffects es) => ObjectiveHost -> WS.ObjectiveRef -> Eff es (Either ObjectiveError CP.ObjectiveVersion)
readObjectiveVersion host reference = do
  grant <- liftIO (admitObjectiveAction host "read-version" (toJSON reference))
  either (pure . Left) (\access -> Store.readVersion access reference) grant

resolveAssignment :: (Store.ObjectiveEffects es) => ObjectiveHost -> WS.ObjectiveRef -> Eff es (Either ObjectiveError ObjectiveAssociation)
resolveAssignment host reference = do
  grant <- liftIO (admitObjectiveAction host "resolve-assignment" (toJSON reference))
  either (pure . Left) (\access -> Store.resolveAssignment access reference) grant

readCheckpointVersion :: (Store.ObjectiveEffects es) => ObjectiveHost -> WS.ObjectiveRef -> Eff es (Either ObjectiveError CP.ObjectiveVersion)
readCheckpointVersion host reference = do
  grant <- liftIO (admitObjectiveAction host "current-checkpoint" (toJSON reference))
  either (pure . Left) (\access -> Store.currentCheckpoint access reference) grant

readInternalReceipt :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> InternalCommand -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readInternalReceipt host objective expected operation command = do
  grant <- liftIO (admitObjectiveAction host (commandTag (Internal command)) (toJSON (objective, expected, operation, Internal command)))
  either (pure . Left) (\access -> Store.readMutationReceipt access objective expected operation (Internal command)) grant

lookupCoordinationScope :: (Store.ObjectiveEffects es) => ObjectiveHost -> Coordination.CoordinatorRun -> Maybe (ExecutionDigest "coordination-scope") -> Eff es (Either ObjectiveError (Maybe Coordination.CoordinationScope))
lookupCoordinationScope host run pinned = do
  grant <- liftIO (admitObjectiveAction host "lookup-coordination-scope" (toJSON (run, pinned)))
  either (pure . Left) (\access -> Store.lookupCoordinationScope access run pinned) grant

executeCommand :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> Command -> Eff es (Either ObjectiveError Receipt)
executeCommand host objective expected operation command = execute host objective expected operation (Public command)

executeInternal :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> InternalCommand -> Eff es (Either ObjectiveError Receipt)
executeInternal host objective expected operation command = execute host objective expected operation (Internal command)

execute :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> Mutation -> Eff es (Either ObjectiveError Receipt)
execute host objective expected operation command = executeWithTrackerCommit host Nothing objective expected operation command (\_ _ -> pure ())

executeCommandWithTrackerCommit :: (Store.ObjectiveEffects es) => ObjectiveHost -> AccessPrincipal -> ObjectiveId -> StateRevision "objective" -> OperationId -> Command -> (Objective -> Receipt -> Transaction ()) -> Eff es (Either ObjectiveError Receipt)
executeCommandWithTrackerCommit host actor objective expected operation command = executeWithTrackerCommit host (Just actor) objective expected operation (Public command)

executeWithTrackerCommit :: (Store.ObjectiveEffects es) => ObjectiveHost -> Maybe AccessPrincipal -> ObjectiveId -> StateRevision "objective" -> OperationId -> Mutation -> (Objective -> Receipt -> Transaction ()) -> Eff es (Either ObjectiveError Receipt)
executeWithTrackerCommit host expectedActor objective expected operation command trackerCommit = do
  grant <- liftIO (admitObjectiveAction host (commandTag command) (toJSON (objective, expected, operation, command)))
  case grant of
    Left err -> pure (Left err)
    Right access | maybe False (/= access.actor) expectedActor -> pure (Left ObjectiveDenied)
    Right access -> do
      original <- Store.lookupCommandReceipt access objective operation command
      case original of
        Left err -> pure (Left err)
        Right (Just _) -> Store.execute access objective expected operation command
        Right Nothing | host.settings.enabled == ObjectivesDisabled -> pure (Left ObjectiveDenied)
        Right Nothing -> do
          models <- case command of
            Public BindConversation {} -> Conversation.checkMemoryModels
            _ -> pure (Right ())
          checked <- liftIO $ trySyncIO do
            internal <- case command of Public _ -> pure (Right ()); Internal value -> host.verifyInternal access.actor value
            evidence <- forM (evidenceInputs command) \input -> case input of
              Attestation {} -> pure (Right (input, EvidenceVerification CheckPassed (Just input.criterion) input.journey))
              ResultEvidence {result = WorkerResult receipt _} -> pure (Right (input, EvidenceVerification (if receipt.disposition == WS.AssignmentSucceeded then ResultObserved else CheckFailed) Nothing NoJourney))
              ResultEvidence {result} -> fmap (input,) <$> host.verifyResult result
            pure (models >> internal >> sequence evidence)
          case checked of
            Left _ -> pure (Left ObjectiveUnavailable)
            Right validation -> do
              fresh <- liftIO (admitObjectiveAction host (commandTag command) (toJSON (objective, expected, operation, command)))
              case fresh of
                Left err -> pure (Left err)
                Right current | current.actor /= access.actor -> pure (Left ObjectiveDenied)
                Right current -> case validation of
                  Left err | err `elem` [ObjectiveDenied, ObjectiveUnavailable, ObjectiveUnresolved] -> pure (Left err)
                  Left err -> Store.execute (current & #refusal .~ Just err) objective expected operation command
                  Right evidence -> Store.executeWithTrackerCommit (current & #checks .~ evidence) objective expected operation command trackerCommit

readCommandReceipt :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> OperationId -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readCommandReceipt host objective operation = do
  grant <- liftIO (admitObjectiveAction host "read-receipt" (toJSON (objective, operation)))
  either (pure . Left) (\access -> Store.readReceipt access objective operation) grant

readConversationTurn :: (Store.ObjectiveEffects es) => ObjectiveHost -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError (Maybe Conversation.TurnAdmission))
readConversationTurn host run turn conversation = do
  grant <- liftIO (admitObjectiveAction host "read-conversation-turn" (toJSON (run, turn, conversation)))
  either (pure . Left) (\access -> Store.readConversationTurn access run turn conversation) grant

lookupCreatedObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> OperationId -> CreationOrigin -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedObjective host operation origin = do
  grant <- liftIO (admitObjectiveAction host "lookup-created" (toJSON (operation, origin)))
  either (pure . Left) (\access -> Store.lookupCreatedObjective access operation origin) grant

-- This predicate is a trusted runtime value, never decoded from tool JSON.
lookupCreatedInScope :: (Store.ObjectiveEffects es) => ObjectiveHost -> AccessPrincipal -> ObjectiveId -> CreationOrigin -> (CreationOrigin -> Bool) -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedInScope host expectedActor objective scope within = do
  grant <- liftIO (admitObjectiveAction host "lookup-created-in-scope" (toJSON (objective, scope)))
  case grant of
    Right access | access.actor == expectedActor -> Store.lookupCreatedInScope access objective within
    Right _ -> pure (Left ObjectiveDenied)
    Left err -> pure (Left err)

-- | Runtime-only turn admission. Run/turn coordinates never come from a model
-- tool's JSON; this freezes the association before that turn can dispatch work.
admitConversationTurn :: (Store.ObjectiveEffects es) => ObjectiveHost -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError Conversation.TurnAdmission)
admitConversationTurn host run turn conversation = do
  grant <- liftIO (admitObjectiveAction host "admit-conversation-turn" (toJSON (run, turn, conversation)))
  either (pure . Left) (\access -> Store.admitConversationTurn access run turn conversation) grant

trySyncIO :: IO a -> IO (Either SomeException a)
trySyncIO action =
  try action >>= \case
    Left exception | Just (_ :: SomeAsyncException) <- fromException exception -> throwIO exception
    outcome -> pure outcome
