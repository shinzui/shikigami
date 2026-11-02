{-# LANGUAGE DataKinds #-}

-- | Authenticated admission for every objective adapter. Host callbacks consume
-- verified caller/runtime context; none is populated from command JSON.
module Shikigami.Objective.Capability
  ( ObjectiveHost (..),
    createObjective,
    readObjective,
    readObjectiveVersion,
    executeCommand,
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
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Command
import Shikigami.Objective.Conversation qualified as Conversation
import Shikigami.Objective.Store qualified as Store
import Shikigami.Objective.Types
import Shikigami.Prelude
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

admit :: ObjectiveHost -> Text -> Aeson.Value -> IO (Either ObjectiveError Access)
admit host label semantic = do
  attempted <- trySyncIO do
    authenticated <- host.authenticate
    case authenticated of
      Left err -> pure (Left err)
      Right actor | host.settings.enabled == ObjectivesEnabled && validPrincipal actor -> do
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

createObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> OperationId -> Maybe CreationOrigin -> CreateRequest -> Eff es (Either ObjectiveError Receipt)
createObjective host operation origin request = do
  grant <- liftIO (admit host "create" (toJSON (operation, origin, request)))
  case grant of
    Left err -> pure (Left err)
    Right access -> do
      Store.create access operation origin request do
        verified <- trySyncIO do
          checked <- case origin of Nothing -> pure (Right ()); Just value -> host.verifyOrigin access.actor value
          fresh <- admit host "create" (toJSON (operation, origin, request))
          pure (checked >> (fresh >>= \current -> if current.actor == access.actor then Right () else Left ObjectiveDenied))
        pure (either (const (Left ObjectiveUnavailable)) id verified)

readObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> Eff es (Either ObjectiveError Objective)
readObjective host objective = do
  grant <- liftIO (admit host "read" (toJSON objective))
  either (pure . Left) (\access -> Store.read access objective) grant

readObjectiveVersion :: (Store.ObjectiveEffects es) => ObjectiveHost -> WS.ObjectiveRef -> Eff es (Either ObjectiveError CP.ObjectiveVersion)
readObjectiveVersion host reference = do
  grant <- liftIO (admit host "read-version" (toJSON reference))
  either (pure . Left) (\access -> Store.readVersion access reference) grant

executeCommand :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> Command -> Eff es (Either ObjectiveError Receipt)
executeCommand host objective expected operation command = execute host objective expected operation (Public command)

executeInternal :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> InternalCommand -> Eff es (Either ObjectiveError Receipt)
executeInternal host objective expected operation command = execute host objective expected operation (Internal command)

execute :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> StateRevision "objective" -> OperationId -> Mutation -> Eff es (Either ObjectiveError Receipt)
execute host objective expected operation command = do
  grant <- liftIO (admit host (commandTag command) (toJSON (objective, expected, operation, command)))
  case grant of
    Left err -> pure (Left err)
    Right access -> do
      original <- Store.lookupCommandReceipt access objective operation command
      case original of
        Left err -> pure (Left err)
        Right (Just _) -> Store.execute access objective expected operation command
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
              fresh <- liftIO (admit host (commandTag command) (toJSON (objective, expected, operation, command)))
              case fresh of
                Left err -> pure (Left err)
                Right current | current.actor /= access.actor -> pure (Left ObjectiveDenied)
                Right current -> case validation of
                  Left err | err `elem` [ObjectiveDenied, ObjectiveUnavailable, ObjectiveUnresolved] -> pure (Left err)
                  Left err -> Store.execute (current & #refusal .~ Just err) objective expected operation command
                  Right evidence -> Store.execute (current & #checks .~ evidence) objective expected operation command

readCommandReceipt :: (Store.ObjectiveEffects es) => ObjectiveHost -> ObjectiveId -> OperationId -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readCommandReceipt host objective operation = do
  grant <- liftIO (admit host "read-receipt" (toJSON (objective, operation)))
  either (pure . Left) (\access -> Store.readReceipt access objective operation) grant

readConversationTurn :: (Store.ObjectiveEffects es) => ObjectiveHost -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError (Maybe Conversation.TurnAdmission))
readConversationTurn host run turn conversation = do
  grant <- liftIO (admit host "read-conversation-turn" (toJSON (run, turn, conversation)))
  either (pure . Left) (\access -> Store.readConversationTurn access run turn conversation) grant

lookupCreatedObjective :: (Store.ObjectiveEffects es) => ObjectiveHost -> OperationId -> CreationOrigin -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedObjective host operation origin = do
  grant <- liftIO (admit host "lookup-created" (toJSON (operation, origin)))
  either (pure . Left) (\access -> Store.lookupCreatedObjective access operation origin) grant

-- This predicate is a trusted runtime value, never decoded from tool JSON.
lookupCreatedInScope :: (Store.ObjectiveEffects es) => ObjectiveHost -> AccessPrincipal -> ObjectiveId -> CreationOrigin -> (CreationOrigin -> Bool) -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedInScope host expectedActor objective scope within = do
  grant <- liftIO (admit host "lookup-created-in-scope" (toJSON (objective, scope)))
  case grant of
    Right access | access.actor == expectedActor -> Store.lookupCreatedInScope access objective within
    Right _ -> pure (Left ObjectiveDenied)
    Left err -> pure (Left err)

-- | Runtime-only turn admission. Run/turn coordinates never come from a model
-- tool's JSON; this freezes the association before that turn can dispatch work.
admitConversationTurn :: (Store.ObjectiveEffects es) => ObjectiveHost -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError Conversation.TurnAdmission)
admitConversationTurn host run turn conversation = do
  grant <- liftIO (admit host "admit-conversation-turn" (toJSON (run, turn, conversation)))
  either (pure . Left) (\access -> Store.admitConversationTurn access run turn conversation) grant

trySyncIO :: IO a -> IO (Either SomeException a)
trySyncIO action =
  try action >>= \case
    Left exception | Just (_ :: SomeAsyncException) <- fromException exception -> throwIO exception
    outcome -> pure outcome
