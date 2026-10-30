{-# LANGUAGE OverloadedRecordDot #-}

-- | @shikigami runs show@: one agent run, across both libraries that hold it.
--
-- An agent run's durable state lives in two places that know nothing about each
-- other. /keiro/ owns the workflow instance — its status, generation, attempt
-- count, lease, and last error. /kioku/ owns the session — the agent that ran,
-- what it was focused on, its summary, its error, and its recorded turns. Keiro
-- has no business knowing about kioku and kioku has no business knowing about
-- keiro, so neither library can answer \"what happened to this run\". Joining
-- them is a Shikigami concern by construction, and this module is the join.
--
-- Everything else an operator needs about the keiro half alone is already
-- served by the mounted @keiro-ops@ tree — @wf show@, @wf steps@, @wf journal@.
-- This command exists only for the part that tree structurally cannot provide.
--
-- == How the two identities relate
--
-- They are not equal, and an early version of the plan behind this module
-- assumed they were. The workflow id is derived by @runJobWorkflowId@ from
-- the run job's natural idempotency key, hashing keys with journal separators
-- to a stable UUIDv5. The session id is minted fresh by
-- @genSessionId@ when the session is opened. Nothing derives either from the
-- other.
--
-- What links them is the journal. The first step of an agent run is
-- @open-session@, and the value it records /is/ the session id. A danwa
-- conversation records the same thing under @resolve-session@. Keiro exposes
-- recorded step results as an ordinary library read — @loadStepIndex@ returns
-- @Map Text Value@ — so the link is exact and recorded rather than inferred, and
-- there is nothing to disclaim in help text.
--
-- Both step names are tried rather than branching on the workflow name. The step
-- name is what the journal actually holds; keying off the workflow name would
-- make this command need to know which workflows exist, and it would break the
-- next time one is added.
--
-- == Why there is no SQL here
--
-- Every read is an exported operation of the library that owns the state:
-- @lookupInstance@ and @loadStepIndex@ from keiro, @getById@ and @getTurns@ from
-- kioku. Keiro's ADR-28
-- (@mori:\/\/shinzui\/keiro\/okf\/adrs\/concepts\/ADR-28@) requires exactly this
-- and forbids an operator command reading another library's private tables, so
-- the hasql @Statement@ an earlier plan revision specified would have been a
-- rule violation rather than a shortcut.
--
-- == A conversation is inspected one epoch at a time
--
-- A conversation workflow id carries an epoch
-- (@docs\/adr\/0018-a-workflow-that-ends-is-re-keyed-by-epoch.md@), and each
-- epoch opens its own session. So @runs show@ on a conversation reports that
-- epoch, not the whole conversation. Following the chain is kioku's @getChain@
-- and is deliberately not done here.
module Shikigami.Server.Command.Runs
  ( runRunsShow,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, (:>))
import Keiro.Workflow
  ( WorkflowId (WorkflowId),
    WorkflowInstanceRow (..),
    WorkflowName (WorkflowName),
    loadStepIndex,
  )
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.Status qualified as Status

-- @lookupInstance@ and @statusToText@ are not re-exported by "Keiro.Workflow";
-- the module that owns instance rows exports both.
import Keiro.Workflow.Instance (lookupInstance, statusToText)
import Kioku.Id (SessionId, idText, parseId)
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Workflow (StepResult (StepProduced, StepRefused))
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Decision.ModelCatalog (modelDescriptor, pinnedBinding)
import Shikigami.Execution.Selection (ExecutionSelection (..), ExecutionSelectionFailure, SelectionSource (..), defaultBinding)
import Shikigami.Execution.SelectionStore qualified as SelectionStore
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Migrations (verifyShikigamiMigrations)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | What the journal says about this run's session.
--
-- Three cases, kept apart because collapsing them would make the command lie. A
-- run that has not reached its session step yet and a run whose session kioku
-- refused are both \"no session row\", but they mean opposite things: the first
-- may still succeed, the second is permanently over.
data SessionLink
  = -- | The step recorded a session id, and this is what kioku says about it.
    SessionOpened !SessionId !(Maybe SessionRow) !(Maybe Int)
  | -- | No session step is recorded on this generation yet.
    SessionNotOpened
  | -- | Kioku refused to open the session; the run is permanently over.
    SessionRefused !Text
  | -- | A session step is recorded but this build cannot read it.
    SessionUnreadable !Text

-- | @shikigami runs show \<workflow-name\> \<workflow-id\> [--json]@.
--
-- Both arguments are required because keiro keys an instance by
-- @(workflow_name, workflow_id)@. Defaulting the name to @shikigami.agent-run@
-- would be a convenience that lies the moment a conversation workflow is
-- inspected the same way.
runRunsShow :: Text -> Text -> Bool -> AppConfig -> IO ()
runRunsShow wfName wfId asJson config = do
  connectionString <- revealSecretText <$> requireDatabaseUrl "runs show" config
  verifyShikigamiMigrations connectionString
  withStore (defaultConnectionSettings connectionString) \store -> do
    gathered <- gather store wfName wfId
    case gathered of
      Left storeError -> die ("store error: " <> Text.pack (show storeError))
      Right Nothing
        | asJson && wfName == "shikigami.agent-run" -> do
            accepted <- Ledger.lookupRunRequestById store.pool wfId
            case accepted of
              Left _ -> die "run lifecycle store is unavailable"
              Right Nothing -> die ("no workflow instance named " <> wfName <> " with id " <> wfId)
              Right (Just request) -> do
                result <- Status.deriveRunStatus store (AgentName request.agentName) wfId
                case result of
                  Left failure -> die (Status.runStatusFailureText failure)
                  Right status -> LazyChar8.putStrLn (Aeson.encode (withLifecycle status (object ["workflow" .= Aeson.Null, "session" .= Aeson.Null])))
        | otherwise -> die ("no workflow instance named " <> wfName <> " with id " <> wfId)
      Right (Just (row, link))
        | asJson -> do
            -- The journal is authoritative for the agent name, including failures before session open.
            steps <- runStoreIO store (loadStepIndex (WorkflowName wfName) (WorkflowId wfId) (fromIntegral row.generation))
            let agent = case steps of
                  Right index ->
                    Map.lookup "ingest-job" index >>= \value -> case Aeson.fromJSON value of
                      Aeson.Success (job :: RunJob) -> Just job.agentName
                      _ -> Nothing
                  _ -> Nothing
            finalLifecycle <- case agent of
              Just name | wfName == "shikigami.agent-run" -> Status.deriveRunStatus store name wfId
              _ -> pure (Right Nothing)
            case finalLifecycle of
              Left failure -> die (Status.runStatusFailureText failure)
              Right status -> do
                execution <- either (const (die "execution inspection store is unavailable")) (executionInspection config store) steps
                LazyChar8.putStrLn (Aeson.encode (withExecution execution (withLifecycle status (runJson row link))))
        | otherwise -> do
            TextIO.putStr (renderRun row link)
            steps <- runStoreIO store (loadStepIndex (WorkflowName wfName) (WorkflowId wfId) (fromIntegral row.generation))
            execution <- either (const (die "execution inspection store is unavailable")) (executionInspection config store) steps
            TextIO.putStrLn "execution"
            LazyChar8.putStrLn (Aeson.encode execution)
  where
    die message = do
      hPutStrLn stderr ("runs show: " <> Text.unpack message)
      exitFailure

-- Inspect immutable public descriptors and at most 100 normalized call facts.
-- Effective provider options and transcript payloads are intentionally absent.
executionInspection :: AppConfig -> KirokuStore -> Map Text Value -> IO Value
executionInspection config store steps =
  case Map.lookup "resolve-execution-selection" steps <|> Map.lookup "resolve-conversation-execution" steps of
    Nothing -> pure (object ["status" .= ("notSelected" :: Text)])
    Just value -> case Aeson.fromJSON value :: Aeson.Result (Either ExecutionSelectionFailure (Maybe ExecutionSelection)) of
      Aeson.Error _ -> pure (object ["status" .= ("unreadableSelection" :: Text)])
      Aeson.Success (Left refusal) -> pure (object ["status" .= ("refused" :: Text), "reason" .= refusal])
      Aeson.Success (Right Nothing) -> pure (object ["status" .= ("unusedDefault" :: Text)])
      Aeson.Success (Right (Just selection)) -> do
        base <- newBehaviorEnvFor Log.silentLogger config.behaviorProvider Nothing
        let available = case selection.source of
              ProcessDefault -> either (const False) ((== selection.descriptor) . modelDescriptor) (defaultBinding base.model base.options)
              DeclaredAlias -> either (const False) (either (const False) (const True) . (`pinnedBinding` selection.descriptor)) config.decisionModelCatalog
        facts <- runStoreIO store (SelectionStore.inspectSelection selection.assignmentId)
        pure
          ( object
              [ "status" .= ("selected" :: Text),
                "assignmentId" .= selection.assignmentId,
                "descriptor" .= selection.descriptor,
                "profile" .= selection.profile,
                "rootId" .= selection.rootId,
                "permittedAliases" .= selection.permittedAliases,
                "admittedAt" .= selection.admittedAt,
                "bindingAvailability" .= (if available then "available" else "PinnedBindingUnavailable" :: Text),
                "calls" .= case facts of
                  Left _ -> object ["status" .= ("unavailable" :: Text)]
                  Right Nothing -> object ["attempts" .= (0 :: Int)]
                  Right (Just (assignment, calls)) -> object ["attempts" .= assignment.attempts, "active" .= assignment.active, "unknown" .= assignment.unknown, "usage" .= assignment.usage, "facts" .= calls]
              ]
          )

withExecution :: Value -> Value -> Value
withExecution execution (Aeson.Object fields) = Aeson.Object (KeyMap.insert "execution" execution fields)
withExecution _ value = value

-- | Read both halves in one store session.
gather ::
  KirokuStore ->
  Text ->
  Text ->
  IO (Either StoreError (Maybe (WorkflowInstanceRow, SessionLink)))
gather store wfName wfId =
  runStoreIO store do
    found <- lookupInstance (WorkflowName wfName) (WorkflowId wfId)
    traverse withSession found
  where
    withSession row = do
      steps <- loadStepIndex (WorkflowName wfName) (WorkflowId wfId) (fromIntegral row.generation)
      link <- resolveSession (sessionStep steps)
      pure (row, link)

-- | Follow a recorded session id into kioku.
resolveSession :: (Store :> es, IOE :> es) => SessionLink -> Eff es SessionLink
resolveSession = \case
  SessionOpened sid _ _ -> do
    row <- Session.getById shikigamiMemorySpace sid
    turns <- Session.getTurns shikigamiMemorySpace sid
    pure (SessionOpened sid (either (const Nothing) id row) (either (const Nothing) (Just . length) turns))
  other -> pure other

-- | Find the step that carries the session id, and decode it.
--
-- @open-session@ is an agent run and @resolve-session@ is a conversation turn.
-- Both record a session id; the first records it wrapped in a 'StepResult' whose
-- produced arm encodes as the bare id, the second records the bare id directly,
-- and 'StepResult''s decoder reads either.
--
-- The id is decoded as 'Text' and then parsed with kioku's strict 'parseId'
-- rather than through a @FromJSON SessionId@ instance, because 'parseId' rejects
-- a wrong type prefix and names both prefixes when it does.
sessionStep :: Map Text Value -> SessionLink
sessionStep steps =
  case Map.lookup "open-session" steps <|> Map.lookup "resolve-session" steps of
    Nothing -> SessionNotOpened
    Just recorded ->
      case Aeson.fromJSON recorded of
        Aeson.Error detail -> SessionUnreadable (Text.pack detail)
        Aeson.Success (StepRefused detail) -> SessionRefused detail
        Aeson.Success (StepProduced raw) ->
          case parseId raw of
            Left detail -> SessionUnreadable detail
            Right sid -> SessionOpened sid Nothing Nothing

-- | Two labelled blocks rather than a table: this is one record, and a
-- single-row table makes a reader count columns to find a field.
renderRun :: WorkflowInstanceRow -> SessionLink -> Text
renderRun row link =
  Text.unlines
    ( "workflow"
        : map field workflowFields
          <> ["", "session"]
          <> sessionLines
    )
  where
    field (label, value) = "  " <> pad label <> value
    pad label = label <> Text.replicate (12 - Text.length label) " "

    workflowFields =
      [ ("name", row.workflowName),
        ("id", row.workflowId),
        ("status", statusToText row.status),
        ("generation", Text.pack (show row.generation)),
        ("attempts", Text.pack (show row.attempts)),
        ("last error", orDash row.lastError),
        ("leased by", orDash row.leasedBy),
        ("created", stamp row.createdAt),
        ("updated", stamp row.updatedAt),
        ("completed", maybe "-" stamp row.completedAt)
      ]

    sessionLines = case link of
      SessionNotOpened ->
        ["  no session opened yet on this generation"]
      SessionRefused detail ->
        ["  kioku refused to open a session: " <> detail]
      SessionUnreadable detail ->
        ["  a session step is recorded but could not be read: " <> detail]
      SessionOpened sid Nothing _ ->
        [ "  " <> pad "id" <> idText sid,
          "  recorded by the run, but kioku has no session row for it"
        ]
      SessionOpened sid (Just session) turns ->
        map
          field
          [ ("id", idText sid),
            ("agent", session.agentId),
            ("focus", session.focus),
            ("status", session.status),
            ("summary", orDash session.summary),
            ("error", orDash session.errorMessage),
            ("started", stamp session.startedAt),
            ("completed", maybe "-" stamp session.completedAt),
            ("turns", maybe "?" (Text.pack . show) turns)
          ]

-- | Both halves as one object, so a consumer does not have to correlate two.
runJson :: WorkflowInstanceRow -> SessionLink -> Value
runJson row link =
  object
    [ "workflow"
        .= object
          [ "name" .= row.workflowName,
            "id" .= row.workflowId,
            "status" .= statusToText row.status,
            "generation" .= row.generation,
            "attempts" .= row.attempts,
            "last_error" .= row.lastError,
            "leased_by" .= row.leasedBy,
            "created_at" .= row.createdAt,
            "updated_at" .= row.updatedAt,
            "completed_at" .= row.completedAt
          ],
      "session" .= sessionJson link
    ]

-- | @state@ is present on every shape, so a consumer branches on it rather than
-- inferring meaning from which keys are missing.
sessionJson :: SessionLink -> Value
sessionJson = \case
  SessionNotOpened -> object ["state" .= ("not_opened" :: Text)]
  SessionRefused detail ->
    object ["state" .= ("refused" :: Text), "detail" .= detail]
  SessionUnreadable detail ->
    object ["state" .= ("unreadable" :: Text), "detail" .= detail]
  SessionOpened sid Nothing _ ->
    object ["state" .= ("missing" :: Text), "id" .= idText sid]
  SessionOpened sid (Just session) turns ->
    object
      [ "state" .= ("opened" :: Text),
        "id" .= idText sid,
        "agent" .= session.agentId,
        "focus" .= session.focus,
        "status" .= session.status,
        "summary" .= session.summary,
        "error" .= session.errorMessage,
        "started_at" .= session.startedAt,
        "completed_at" .= session.completedAt,
        "turns" .= turns
      ]

orDash :: Maybe Text -> Text
orDash = \case
  Just value | not (Text.null (Text.strip value)) -> value
  _ -> "-"

stamp :: UTCTime -> Text
stamp = Text.pack . iso8601Show

withLifecycle :: Maybe Status.RunStatusView -> Value -> Value
withLifecycle status (Aeson.Object fields) = Aeson.Object (KeyMap.insert "lifecycle" (maybe Aeson.Null render status) fields)
  where
    render view = object ["status" .= Status.lifecycleText view.lifecycle, "failure" .= fmap renderFailure view.failure]
    renderFailure failure = object ["kind" .= Status.failureKindText failure.kind, "reason" .= failure.reason]
withLifecycle _ value = value
