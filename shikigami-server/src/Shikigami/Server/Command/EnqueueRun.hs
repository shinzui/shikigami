module Shikigami.Server.Command.EnqueueRun
  ( runEnqueueRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.List (find, isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Loader (loadAgentsReport, loadedAgents)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Payload (readPayloadArgument)
import Shikigami.Agent.Run.Key (runKeyText)
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.App.Config (AppConfig (agentsDirectory, directorySettings), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Trigger.Enqueue (addressedRunKeyIn, addressedRunKeyWithKey, enqueueAddressedRunIn, enqueueAddressedRunWithKeyIn, ensureRunQueue)
import Shikigami.Trigger.RequestKey qualified as Addressed
import System.Exit (exitFailure)
import System.FilePath (isAbsolute)
import System.IO (hPutStrLn, stderr)

-- | @enqueue-run <agent> [--payload <json>] [--conversation] [--key <text>]@:
-- the addressed (event-trigger) producer. Enqueues a RunJob onto the shared
-- @shikigami_run_jobs@ pgmq queue (which the worker, EP-5, drains). Reuses the
-- kioku store's hasql pool.
--
-- The route is declared, not inferred: without @--conversation@ the job runs the
-- durable agent-run workflow, and with it the job is a danwa conversation turn
-- whose payload must decode as an addressed message.
--
-- The idempotency key is derived from the agent and the payload unless @--key@
-- supplies one, so invoking this twice for the same logical event produces one
-- run. It used to be derived from the wall clock, which made a retried
-- invocation a second run.
--
-- The connection string comes from the resolved configuration under
-- @database.connection_string@. It is demanded here rather than by the whole
-- @shikigami@ command line because sibling subcommands such as @validate@ run
-- entirely offline.
runEnqueueRun :: AgentName -> Maybe String -> Bool -> Maybe Addressed.RequestKey -> Maybe String -> AppConfig -> IO ()
runEnqueueRun target mpayload conversation mkey workspace config = do
  -- The repository the run works in, journaled as a Mori identity or an
  -- absolute checkout path (the local-operator tier resolves it).
  -- A worker resolves a path from its own directory, so only an absolute
  -- path or a Mori identity names the same checkout for both.
  repository <- case workspace of
    Nothing -> pure Nothing
    Just named
      | "mori://" `isPrefixOf` named || isAbsolute named -> pure (Just (Text.pack named))
      | otherwise -> die "--workspace must be a mori:// identity or an absolute checkout path"
  let agent = Text.unpack (agentNameText target)
  supplied <- readPayloadArgument mpayload
  payload <- case supplied of
    Nothing -> pure (Aeson.object [])
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr "enqueue-run: payload input is not valid JSON"
        exitFailure
  report <- loadAgentsReport ((.agentsDirectory) config)
  decl <-
    case find ((== target) . (.name)) (loadedAgents report) of
      Nothing -> die ("unknown or unloadable agent " <> agent)
      Just found -> pure found
  directoryRuntime <-
    Directory.startDirectory Log.silentLogger ((.directorySettings) config) >>= \case
      Left problem -> die ("directory admission failed: " <> Text.unpack problem)
      Right runtime -> pure runtime
  admittedIdentity <-
    Directory.identityAdmission
      ((.handle) directoryRuntime)
      (declaredPrincipalId decl)
      ((.name) decl)
      >>= either (die . Text.unpack) pure
  connStr <- revealSecretText <$> requireDatabaseUrl "enqueue-run" config
  verifyShikigamiMigrations connStr
  withStore (defaultConnectionSettings connStr) $ \st -> do
    -- This is one of the two startup paths that used to rely on the per-send
    -- createQueue inside enqueueRunJob, so it reconciles the queue itself now.
    queueResult <- ensureRunQueue (pool st)
    case queueResult of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: run-job queue reconciliation failed: " <> show e)
        exitFailure
      Right () -> pure ()
    let route = if conversation then ConversationWorkflowRoute else AgentWorkflowRoute
        key = maybe (addressedRunKeyIn target route payload repository) (addressedRunKeyWithKey target route) mkey
    res <- case mkey of
      Nothing -> enqueueAddressedRunIn (pool st) admittedIdentity target route payload repository
      Just requestKey -> enqueueAddressedRunWithKeyIn (pool st) admittedIdentity target route payload requestKey repository
    case res of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: " <> show e)
        exitFailure
      Right mid ->
        putStrLn
          ( "enqueued run job "
              <> show mid
              <> " for agent "
              <> agent
              <> " with idempotency key "
              <> Text.unpack (maybe (runKeyText key) Addressed.requestKeyText mkey)
          )
  where
    declaredPrincipalId AgentDecl {identity = Nothing} = Nothing
    declaredPrincipalId AgentDecl {identity = Just IdentityDecl {principal}} = Just principal

    die message = do
      hPutStrLn stderr ("enqueue-run: " <> message)
      exitFailure
