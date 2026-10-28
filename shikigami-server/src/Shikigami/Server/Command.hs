-- | The @shikigami@ administrative command line.
--
-- One binary with subcommands, rather than one binary per command, because these
-- are short-lived operator actions rather than long-running roles: validating a
-- manifest, rendering a lifecycle diagram, enqueuing a run, publishing a fixture
-- envelope, or standing up a downstream stub for a local end-to-end run. Nothing
-- here supervises anything, and none of it is what @shikigami-server@ serves.
--
-- It lives in @shikigami-server@ because these commands reach downstream HTTP and
-- Kafka surfaces the server package already owns, and because the package
-- dependency graph gives them nowhere else to live: @shikigami-workers@ may not
-- be imported by the server, and core may hold no listener.
--
-- == How configuration reaches a subcommand
--
-- Each subcommand parser produces a pair: the action to run, which takes the
-- resolved 'Shikigami.App.Config.AppConfig', and any command-line configuration
-- sources the subcommand itself contributes. Sources are how a flag like
-- @--broker@ survives the move to typed configuration: it is not a private
-- parser feeding a private value, it is an ordinary Settei source aimed at the
-- declared @kafka.broker@ key. So @--broker@ and @--set kafka.broker=…@ mean the
-- same thing, both appear in @--explain-config@ with their spelling, and neither
-- can disagree with the other about defaults.
--
-- The subcommand is optional so that @shikigami --describe-config@ works with no
-- command at all. Invoking the binary with neither a command nor a diagnostic
-- prints a pointer to @--help@ and exits with the reserved usage status.
--
-- The parser produces this pair rather than a bare @IO ()@, so a test can drive
-- @--help@ for every subcommand purely with @optparse-applicative@'s
-- @execParserPure@.
module Shikigami.Server.Command
  ( adminInfo,
    adminPrefs,
    adminSubcommands,
    AdminAction,
    runAdmin,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Options.Applicative
import Settei.Optparse (namedOption)
import Settei.Source (Source)
import Shikigami.App.Config (AppConfig, Role (AdminRole), kafkaActivityTopicKey, kafkaBrokerKey, sinksDanwaBaseUrlKey)
import Shikigami.App.Config.Load
  ( ConfigOptions (..),
    configOptions,
    runAppConfig,
    usageExitCode,
  )
import Shikigami.App.Version (versionOption)
import Shikigami.Server.Command.Agents (runAgentsList, runAgentsSync)
import Shikigami.Server.Command.DanwaSpike (runDanwaSpike)
import Shikigami.Server.Command.EnqueueRun (runEnqueueRun)
import Shikigami.Server.Command.Executions (runExecutionsInspect)
import Shikigami.Server.Command.Grants (runGrantsGrant, runGrantsList, runGrantsRevoke)
import Shikigami.Server.Command.Ops (opsInvocationParser, runOps)
import Shikigami.Server.Command.PublishFixture (runPublishFixture)
import Shikigami.Server.Command.RenderLifecycle (runRenderLifecycle)
import Shikigami.Server.Command.ResolveApproval (resolveApprovalOptionsParser, runResolveApproval)
import Shikigami.Server.Command.Resources (runResourcesInspect)
import Shikigami.Server.Command.Runs (runRunsShow)
import Shikigami.Server.Command.StubKanmon (runStubKanmonCmd)
import Shikigami.Server.Command.StubKawa (runStubKawaCmd)
import Shikigami.Server.Command.Validate (runValidate)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | What a subcommand contributes: the work to do once configuration is
-- resolved, plus the configuration sources its own flags supplied.
type AdminAction = (AppConfig -> IO (), [Source])

-- | The whole @shikigami@ command line.
--
-- The chosen command is either one of this repository's own subcommands or one
-- of the mounted @keiro-ops@ groups, which is why the two are an alternative
-- rather than entries in one list. @keiro-ops@ exports its tree as a whole
-- 'ParserInfo' over an abstract @OpsInvocation@, so its groups cannot be
-- unpacked into 'adminSubcommands' and mounted individually — see
-- "Shikigami.Server.Command.Ops".
--
-- Shikigami's own subcommands come first so that a name appearing in both
-- resolves here rather than upstream. None collide today; if one ever does,
-- this is where the collision is decided, and deliberately.
adminInfo :: ParserInfo (Maybe AdminAction, ConfigOptions)
adminInfo =
  info
    ( ((,) <$> optional (subparser (foldMap snd adminSubcommands) <|> opsAction) <*> configOptions)
        <**> helper
        <**> versionOption "shikigami"
    )
    ( fullDesc
        <> progDesc "shikigami declared-agent runtime: administrative commands"
        <> failureCode usageExitCode
    )
  where
    opsAction = (\invocation -> (runOps invocation, [])) <$> opsInvocationParser

-- | The parser preferences this command line is run with.
--
-- @subparserInline@ matches what @keiro-ops@'s own @main@ uses, so a command an
-- operator reads in Keiro's documentation parses the same way here as it does
-- against the standalone binary. Behavioural parity with the tree we mounted is
-- the whole reason to take a preference from it.
--
-- It is /not/ what makes @--force@ work after a subcommand, which was this
-- comment's original claim and is false: optparse-applicative hands an option
-- it does not recognise back to the parent parser, and @--force@ belongs to the
-- parent, so @wf cancel NAME ID --force@ parses under 'defaultPrefs' too. That
-- was checked by running the binary both ways rather than reasoned about.
--
-- Exported so a test drives the same parser an operator does.
adminPrefs :: ParserPrefs
adminPrefs = prefs subparserInline

-- | Parse the command line, resolve configuration, and run the chosen command.
--
-- Resolution happens after parsing and before the action, so every diagnostic
-- mode completes without a subcommand opening a database, a socket, or a Kafka
-- producer.
runAdmin :: IO ()
runAdmin = do
  (chosen, options) <- customExecParser adminPrefs adminInfo
  case chosen of
    -- A diagnostic with no subcommand is legitimate, and 'runAppConfig' exits
    -- inside it. Reaching the next line therefore means no command was given.
    Nothing -> do
      _ <- runAppConfig AdminRole options
      hPutStrLn stderr "shikigami: no command given; run 'shikigami --help' for the list"
      exitWith (ExitFailure usageExitCode)
    Just (action, sources) -> do
      config <- runAppConfig AdminRole (options & #namedSources .~ (.namedSources) options <> sources)
      action config

-- | Every subcommand, paired with its name.
--
-- Exists so a test can assert each one parses and renders help without listing
-- them a second time.
adminSubcommands :: [(String, Mod CommandFields AdminAction)]
adminSubcommands =
  [ ("validate", command "validate" validateInfo),
    ("render-lifecycle", command "render-lifecycle" renderLifecycleInfo),
    ("enqueue-run", command "enqueue-run" enqueueRunInfo),
    ("resolve-approval", command "resolve-approval" resolveApprovalInfo),
    ("publish-fixture", command "publish-fixture" publishFixtureInfo),
    ("stub-kawa", command "stub-kawa" stubKawaInfo),
    ("stub-kanmon", command "stub-kanmon" stubKanmonInfo),
    ("danwa-spike", command "danwa-spike" danwaSpikeInfo),
    ("grants", command "grants" grantsInfo),
    ("agents", command "agents" agentsInfo),
    ("runs", command "runs" runsInfo),
    ("resources", command "resources" resourcesInfo),
    ("executions", command "executions" executionsInfo)
  ]

executionsInfo :: ParserInfo AdminAction
executionsInfo = info (subparser (command "inspect" inspectInfo) <**> helper) (progDesc "Inspect accepted execution progress without replay payloads")
  where
    inspectInfo = info (parser <**> helper) (progDesc "Show bounded operations, actual attempts, pending receipts and resource holds")
    parser =
      (\execution after limit asJson -> (runExecutionsInspect execution after limit asJson, []))
        <$> strArgument (metavar "EXECUTION" <> help "Accepted execution id")
        <*> option auto (long "after" <> metavar "POSITION" <> value (-1) <> help "Operations after this cursor position (default -1)")
        <*> option auto (long "limit" <> metavar "COUNT" <> value 10 <> help "Operation page size (1-20)")
        <*> switch (long "json" <> help "Emit machine-readable JSON")

resourcesInfo :: ParserInfo AdminAction
resourcesInfo = info (subparser (command "inspect" inspectInfo) <**> helper) (progDesc "Inspect a durable execution resource root")
  where
    inspectInfo = info (parser <**> helper) (progDesc "Show limits, held and unknown usage, cutoff and refusal categories")
    parser =
      (\root asJson -> (runResourcesInspect root asJson, []))
        <$> strArgument (metavar "ROOT" <> help "Admitted execution root id")
        <*> switch (long "json" <> help "Emit machine-readable JSON")

-- | @runs@ is the join across keiro and kioku that neither library can perform.
--
-- Everything about the keiro half alone is already served by the mounted
-- @keiro-ops@ tree; this group exists only for what that tree structurally
-- cannot know. See "Shikigami.Server.Command.Runs".
runsInfo :: ParserInfo AdminAction
runsInfo =
  info
    (subparser (foldMap snd runsSubcommands) <**> helper)
    (progDesc "Inspect an agent run across its keiro workflow and its kioku session")

runsSubcommands :: [(String, Mod CommandFields AdminAction)]
runsSubcommands = [("show", command "show" runsShowInfo)]

-- | @runs show \<workflow-name\> \<workflow-id\> [--json]@.
--
-- Both positional arguments are required because keiro keys an instance by
-- @(workflow_name, workflow_id)@, which is also why @keiro-ops@'s own @wf@ verbs
-- take the pair. Defaulting the name would make the command wrong for
-- conversation workflows rather than merely terse.
runsShowInfo :: ParserInfo AdminAction
runsShowInfo =
  info
    (parser <**> helper)
    (progDesc "Show one run's workflow instance and its kioku session together")
  where
    parser =
      (\wfName wfId asJson -> (runRunsShow wfName wfId asJson, []))
        <$> strArgument (metavar "WORKFLOW_NAME" <> help "such as shikigami.agent-run")
        <*> strArgument (metavar "WORKFLOW_ID" <> help "the run job's idempotency key")
        <*> switch (long "json" <> help "Emit machine-readable JSON")

-- | @agents@ is a group from the start, though it has one verb today.
--
-- @docs\/plans\/23-agent-lifecycle-control-with-meibo-principals.md@ extends
-- this same group with principal and lifecycle state and adds @sync@, and
-- @docs\/plans\/54-key-durable-agent-state-by-meibo-principal.md@ changes what
-- the listing shows. A flat @agents-list@ would have to be renamed to admit
-- either, and renaming an operator verb costs more than declaring the group
-- once.
agentsInfo :: ParserInfo AdminAction
agentsInfo =
  info
    (subparser (foldMap snd agentsSubcommands) <**> helper)
    (progDesc "Inspect the declared agents this deployment has loaded")

agentsSubcommands :: [(String, Mod CommandFields AdminAction)]
agentsSubcommands =
  [ ("list", command "list" agentsListInfo),
    ("sync", command "sync" agentsSyncInfo)
  ]

-- | @agents list [--json]@.
--
-- @--json@ is a flag rather than @--output json@ because the mounted
-- @keiro-ops@ tree already spells this concept that way, and one binary with
-- two spellings for one concept is a usability bug. It contributes no
-- configuration sources: this verb reads the agents directory and nothing else.
agentsListInfo :: ParserInfo AdminAction
agentsListInfo =
  info
    (parser <**> helper)
    (progDesc "List every declared agent, including manifests that failed to load")
  where
    parser =
      (\asJson -> (runAgentsList asJson, []))
        <$> switch (long "json" <> help "Emit machine-readable JSON")

-- | @agents sync [--json] [--alias LEGACY_NAME=agent_...]@ persists the load
-- report and reconciles joined principal ids onto existing sink grants and
-- legacy memory-scope aliases. Database configuration is required at execution
-- time so @agents list@ remains available offline.
agentsSyncInfo :: ParserInfo AdminAction
agentsSyncInfo =
  info
    (parser <**> helper)
    (progDesc "Persist agent load state and reconcile principal-keyed durable state")
  where
    parser =
      (\asJson aliases -> (runAgentsSync asJson (map Text.pack aliases), []))
        <$> switch (long "json" <> help "Emit machine-readable JSON")
        <*> many
          ( strOption
              ( long "alias"
                  <> metavar "LEGACY_NAME=agent_..."
                  <> help "Map a renamed legacy memory/grant name to a current principal (repeatable)"
              )
          )

-- | @grants@ is a group rather than a flat command: list, grant, and revoke
-- share the table but take different arguments, and a flat @grant-sink@ /
-- @revoke-sink@ pair would scatter the C11 surface across the top-level help.
grantsInfo :: ParserInfo AdminAction
grantsInfo =
  info
    (subparser (foldMap snd grantsSubcommands) <**> helper)
    (progDesc "Inspect and change per-agent sink permission grants (C11)")

grantsSubcommands :: [(String, Mod CommandFields AdminAction)]
grantsSubcommands =
  [ ("list", command "list" grantsListInfo),
    ("grant", command "grant" grantsGrantInfo),
    ("revoke", command "revoke" grantsRevokeInfo)
  ]

grantsListInfo :: ParserInfo AdminAction
grantsListInfo =
  info
    (parser <**> helper)
    (progDesc "List sink grants, most-significant page first")
  where
    parser =
      (\limit after -> (runGrantsList limit after, []))
        <$> optional (option auto (long "limit" <> metavar "N" <> help "rows per page (1-200, default 50)"))
        <*> optional (strOption (long "after" <> metavar "AGENT:KIND" <> help "resume after this row"))

grantsGrantInfo :: ParserInfo AdminAction
grantsGrantInfo =
  info
    (parser <**> helper)
    (progDesc "Grant an agent a sink kind")
  where
    parser =
      (\agent kind by -> (runGrantsGrant agent kind by, []))
        <$> argument str (metavar "AGENT")
        <*> argument str (metavar "KIND")
        <*> optional (strOption (long "by" <> metavar "WHO" <> help "recorded in granted_by"))

grantsRevokeInfo :: ParserInfo AdminAction
grantsRevokeInfo =
  info
    (parser <**> helper)
    (progDesc "Revoke an agent's sink kind")
  where
    parser =
      (\agent kind by -> (runGrantsRevoke agent kind by, []))
        <$> argument str (metavar "AGENT")
        <*> argument str (metavar "KIND")
        <*> optional (strOption (long "by" <> metavar "WHO" <> help "recorded in revoked_by"))

-- | A subcommand that reads no configuration at all.
offline :: IO () -> AdminAction
offline action = (const action, [])

validateInfo :: ParserInfo AdminAction
validateInfo =
  info
    ((offline . runValidate <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Parse and validate an agent manifest (.dhall)")

renderLifecycleInfo :: ParserInfo AdminAction
renderLifecycleInfo =
  info
    ((offline . runRenderLifecycle <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Render a Flow agent lifecycle as Mermaid")

enqueueRunInfo :: ParserInfo AdminAction
enqueueRunInfo =
  info
    (parser <**> helper)
    (progDesc "Enqueue an addressed run job for a named agent")
  where
    parser =
      (\agent payload conversation key -> (runEnqueueRun agent payload conversation key, []))
        <$> argument str (metavar "AGENT")
        <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Addressed run payload as JSON"))
        <*> switch (long "conversation" <> help "Route the job as a danwa conversation turn instead of an agent run")
        <*> optional (strOption (long "key" <> metavar "TEXT" <> help "Idempotency key; defaults to one derived from the agent and payload"))

resolveApprovalInfo :: ParserInfo AdminAction
resolveApprovalInfo =
  info
    (parser <**> helper)
    (progDesc "Approve or reject one pending human approval token")
  where
    parser =
      (\(awakeableId, decision) -> (runResolveApproval awakeableId decision, []))
        <$> resolveApprovalOptionsParser

publishFixtureInfo :: ParserInfo AdminAction
publishFixtureInfo =
  info
    (parser <**> helper)
    (progDesc "Publish one Activity Envelope (JSON) onto the activity stream with keiro-* headers")
  where
    parser =
      (\file sources -> (runPublishFixture file, sources))
        <$> argument str (metavar "FILE")
        <*> sourcesOf [brokerOption, topicOption]

stubKawaInfo :: ParserInfo AdminAction
stubKawaInfo =
  info
    (parser <**> helper)
    (progDesc "Run the kawa ingest doorway stub, optionally republishing to a topic")
  where
    parser =
      (\port topic sources -> (runStubKawaCmd port topic, sources))
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> optional (strOption (long "republish-topic" <> metavar "TOPIC" <> help "Re-publish accepted envelopes onto this Kafka topic"))
        <*> sourcesOf [brokerOption]

stubKanmonInfo :: ParserInfo AdminAction
stubKanmonInfo =
  info
    (parser <**> helper)
    (progDesc "Run the authenticated Kanmon channel-egress stub")
  where
    parser =
      (\port conversations -> (runStubKanmonCmd port conversations, []))
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> many (strOption (long "allow-conversation" <> metavar "KEY" <> help "Conversation key the proof route may target (repeatable; default conv_55012)"))

danwaSpikeInfo :: ParserInfo AdminAction
danwaSpikeInfo =
  info
    (parser <**> helper)
    (progDesc "Spike the danwa HTTP client by posting a human message and agent reply")
  where
    parser =
      (\human agent sources -> (runDanwaSpike human agent, sources))
        <$> strOption (long "human" <> metavar "PARTICIPANT" <> help "Human participant id, e.g. part_...")
        <*> strOption (long "agent" <> metavar "PARTICIPANT" <> help "Agent participant id, e.g. part_...")
        <*> sourcesOf [danwaUrlOption]

-- ── Command-line configuration sources ──────────────────────────────────────

-- | Collect the flags that were actually given. An absent flag contributes no
-- source, which is what leaves the environment or the declared default in place.
sourcesOf :: [Parser (Maybe Source)] -> Parser [Source]
sourcesOf parsers = catMaybes <$> sequenceA parsers

brokerOption :: Parser (Maybe Source)
brokerOption =
  namedOption
    "--broker"
    kafkaBrokerKey
    (long "broker" <> metavar "HOST:PORT" <> help "Kafka broker (sets kafka.broker)")

topicOption :: Parser (Maybe Source)
topicOption =
  namedOption
    "--topic"
    kafkaActivityTopicKey
    (long "topic" <> metavar "TOPIC" <> help "Activity topic (sets kafka.activity.topic)")

danwaUrlOption :: Parser (Maybe Source)
danwaUrlOption =
  namedOption
    "--danwa-url"
    sinksDanwaBaseUrlKey
    (long "danwa-url" <> metavar "URL" <> help "danwa base URL (sets sinks.danwa.base_url)")
