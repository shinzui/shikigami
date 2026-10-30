{-# LANGUAGE TypeFamilies #-}

-- | Flow bodies get closed commands and durable event waits, without Store/IO.
-- Registered callers must declare their concrete static label families in the
-- checked workflow, as with the existing memory/decision capabilities.
module Shikigami.Flow.Workers
  ( Workers,
    command,
    commandWithKey,
    awaitEvents,
    runWorkers,
    resolveCoordinationPolicy,
  )
where

import Data.Char (isAlphaNum, isAscii)
import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), currentRunGeneration, currentWorkflow, step)
import Keiro.Workflow.Awakeable (awakeableNamed)
import Kiroku.Store.Effect (Store)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))

data Workers :: Effect where
  WorkerCommand :: Text -> Maybe OperationId -> WorkerCommand -> Workers m (Either SessionError WorkerReply)
  AwaitEvents :: Text -> WorkerSessionId -> Integer -> Int -> Workers m (Either SessionError [EventReceipt])

type instance DispatchOf Workers = Dynamic

command :: (Workers :> es) => Text -> WorkerCommand -> Eff es (Either SessionError WorkerReply)
command label input = send (WorkerCommand label Nothing input)

-- | A coordinator recovering a retained domain intent uses its original key
-- even when its technical workflow has a new epoch or generation.
commandWithKey :: (Workers :> es) => Text -> OperationId -> WorkerCommand -> Eff es (Either SessionError WorkerReply)
commandWithKey label key input = send (WorkerCommand label (Just key) input)

awaitEvents :: (Workers :> es) => Text -> WorkerSessionId -> Integer -> Int -> Eff es (Either SessionError [EventReceipt])
awaitEvents label session after limit = send (AwaitEvents label session after limit)

resolveCoordinationPolicy :: Maybe CoordinationHost -> ActionAuthorizer -> CoordinatorRun -> IO (Either SessionError (Maybe Text))
resolveCoordinationPolicy Nothing _ _ = pure (Right Nothing)
resolveCoordinationPolicy (Just host) authorizer run = owned host (fmap (fmap grantFingerprint) <$> resolveGrant host authorizer run Nothing)

runWorkers :: (Workflow :> es, Store :> es, IOE :> es) => Maybe CoordinationHost -> ActionAuthorizer -> CoordinatorRun -> Either SessionError (Maybe Text) -> Eff (Workers : es) a -> Eff es a
runWorkers configured authorizer run policy = interpret \_ -> \case
  WorkerCommand label key input -> invoke label key input
  AwaitEvents label session after limit -> do
    first <- invoke label Nothing (ReadWorkerEvents session after limit)
    case first of
      Right (WorkerEvents []) -> case enabled of
        Left err -> pure (Left err)
        Right (host, pinned) -> do
          status <- step (StepName ("workers-state-" <> label)) (call host pinned (InspectWorker session (-1) 1) (operation label "status"))
          case status of
            Right (WorkerInspected page) | page.state.phase `elem` [Failed, Cancelled] -> pure (Right [])
            Left err -> pure (Left err)
            _ -> do
              (token, await) <- awakeableNamed (StepName ("workers-events-" <> label))
              (WorkflowName ownerName, WorkflowId ownerId) <- currentWorkflow
              generation <- currentRunGeneration
              subscribed <- step (StepName ("workers-subscribe-" <> label)) do
                key <- operation label "subscribe"
                liftIO
                  ( owned host do
                      resolveGrant host authorizer run (Just pinned) >>= \case
                        Right (Just grant) -> subscribeCommand host authorizer grant key session (SessionListener token generation ownerName ownerId after)
                        Right Nothing -> pure (Left SessionOwnerRefused)
                        Left err -> pure (Left err)
                  )
              case subscribed of
                Left err -> pure (Left err)
                Right _ -> do
                  hint <- await
                  if hint /= session
                    then pure (Left SessionBindingConflict)
                    else do
                      result <- step (StepName ("workers-read-" <> label)) (call host pinned (ReadWorkerEvents session after limit) (operation label "read"))
                      pure (events result)
      _ -> pure (events first)
  where
    enabled = case (configured, policy) of
      (_, Left err) -> Left err
      (Just host, Right (Just pinned)) -> Right (host, pinned)
      _ -> Left (SessionInputRefused "coordination is not admitted for this Flow")
    invoke label key input
      | Text.null label || Text.length label > 64 || not (Text.all (\c -> isAscii c && (isAlphaNum c || c `elem` ['-', '_'])) label) = pure (Left (SessionInputRefused "invalid static worker label"))
      | otherwise = case enabled of
          Left err -> pure (Left err)
          Right (host, pinned) -> step (StepName ("workers-command-" <> label)) (call host pinned input (maybe (operation label "command") pure key))
    call host pinned input keyAction = do
      key <- keyAction
      liftIO
        ( owned host do
            resolveGrant host authorizer run (Just pinned) >>= \case
              Right (Just grant) -> executeCommand host authorizer grant key input
              Right Nothing -> pure (Left SessionOwnerRefused)
              Left err -> pure (Left err)
        )
    operation label suffix = do
      (WorkflowName name, WorkflowId workflow) <- currentWorkflow
      generation <- currentRunGeneration
      pure (OperationId ("workers:" <> versionedDigest "shikigami.flow-worker-command/1" (toJSON (name, workflow, generation, label, suffix :: Text))))
    events = \case Right (WorkerEvents values) -> Right values; Left err -> Left err; _ -> Left SessionBindingConflict

owned :: CoordinationHost -> Eff AppEffects (Either SessionError a) -> IO (Either SessionError a)
owned host action = runAppIO host.services.sessions.appEnv action <&> either (const (Left SessionStorageUnavailable)) id
