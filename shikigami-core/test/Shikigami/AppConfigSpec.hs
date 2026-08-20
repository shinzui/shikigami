-- | The configuration surface behaves the way operators are told it does.
--
-- Four things are worth proving mechanically, because each one fails silently if
-- it breaks.
--
-- /Precedence./ Sources are resolved low to high and a later source wins. Get
-- the order wrong and a process starts successfully with the wrong value; there
-- is no crash and no log line to notice.
--
-- /Strictness./ A misspelled key and a value that will not decode must both be
-- fatal. The tempting alternatives — warn and ignore, or fall back to a lower
-- candidate — turn an operator's mistake into a process running with settings
-- nobody chose.
--
-- /The accepted surface./ The declared keys and the environment bindings are the
-- deployment contract. Renaming either is invisible to the type checker and
-- silently ignores whatever a deployment already sets, so both are pinned here.
-- Forcing the bindings also turns an invalid binding list — a duplicate
-- variable, two variables aimed at one key, structurally overlapping keys — into
-- a test failure rather than a failure in every deployed process.
--
-- /Secrecy./ A connection string must not reach standard output, standard
-- error, a resolution report, or an error message, from any source. The planted
-- token test below is the one that would catch a future setting declared public
-- by mistake.
module Shikigami.AppConfigSpec (tests) where

import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToNominalDiffTime)
import Pgmq (queueNameToText)
import Settei
  ( Key,
    ResolveResult (..),
    Source,
    renderKey,
    renderResolutionJson,
    renderResolutionText,
    renderSchemaJson,
    renderSchemaText,
  )
import Settei.Env (EnvName (..), EnvSnapshot, bindingKey, bindingName, bindingsList, envSnapshot, environmentSource)
import Settei.Optparse (CliOverride, cliOverride, cliSources)
import Settei.Yaml (decodeYamlSource, yamlSourceOptions)
import Shikigami.App.Config
import Shikigami.App.Config.Load
import Shikigami.Trigger.Schedule (CatchUpPolicy (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "application configuration"
    [ surfaceTests,
      precedenceTests,
      strictnessTests,
      requirementTests,
      diagnosticTests,
      secrecyTests
    ]

-- ── The accepted surface ────────────────────────────────────────────────────

surfaceTests :: TestTree
surfaceTests =
  testGroup
    "accepted surface"
    [ testCase "the declaration accepts exactly these keys" $
        fmap renderKey declaredKeys
          @?= [ "agents.directory",
                "approval.deadline_seconds",
                "behavior.model",
                "behavior.provider",
                "credentials.providers.anthropic.api_key",
                "database.connection_string",
                "http.host",
                "http.port",
                "kafka.activity.topic",
                "kafka.broker",
                "kafka.dead_letter.queue",
                "kafka.events.topic",
                "kafka.groups.events",
                "kafka.groups.stream",
                "kafka.include_agent_actors",
                "scheduler.catch_up",
                "sinks.danwa.agent_participant",
                "sinks.danwa.base_url",
                "sinks.kawa.base_url",
                "sinks.kawa.source_segment",
                "sinks.kizashi.base_url",
                "sinks.kizashi.default_recipient",
                "sinks.rei.base_url",
                "worker.run_timeout_seconds"
              ],
      -- Forcing the validated binding list here is the point: an invalid edit
      -- becomes a test failure instead of a failure in every deployed process.
      testCase "every environment variable is bound to exactly one declared key" $
        sort boundVariables
          @?= sort
            [ ("ANTHROPIC_API_KEY", "credentials.providers.anthropic.api_key"),
              ("PG_CONNECTION_STRING", "database.connection_string"),
              ("SHIKIGAMI_AGENTS_DIRECTORY", "agents.directory"),
              ("SHIKIGAMI_APPROVAL_DEADLINE_SECONDS", "approval.deadline_seconds"),
              ("SHIKIGAMI_BEHAVIOR_MODEL", "behavior.model"),
              ("SHIKIGAMI_BEHAVIOR_PROVIDER", "behavior.provider"),
              ("SHIKIGAMI_HTTP_HOST", "http.host"),
              ("SHIKIGAMI_HTTP_PORT", "http.port"),
              ("SHIKIGAMI_KAFKA_ACTIVITY_TOPIC", "kafka.activity.topic"),
              ("SHIKIGAMI_KAFKA_BROKER", "kafka.broker"),
              ("SHIKIGAMI_KAFKA_DEAD_LETTER_QUEUE", "kafka.dead_letter.queue"),
              ("SHIKIGAMI_KAFKA_EVENTS_GROUP", "kafka.groups.events"),
              ("SHIKIGAMI_KAFKA_EVENTS_TOPIC", "kafka.events.topic"),
              ("SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS", "kafka.include_agent_actors"),
              ("SHIKIGAMI_KAFKA_STREAM_GROUP", "kafka.groups.stream"),
              ("SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT", "sinks.danwa.agent_participant"),
              ("SHIKIGAMI_SINKS_DANWA_BASE_URL", "sinks.danwa.base_url"),
              ("SHIKIGAMI_SINKS_KAWA_BASE_URL", "sinks.kawa.base_url"),
              ("SHIKIGAMI_SINKS_KAWA_SOURCE_SEGMENT", "sinks.kawa.source_segment"),
              ("SHIKIGAMI_SINKS_KIZASHI_BASE_URL", "sinks.kizashi.base_url"),
              ("SHIKIGAMI_SINKS_KIZASHI_DEFAULT_RECIPIENT", "sinks.kizashi.default_recipient"),
              ("SHIKIGAMI_SCHEDULER_CATCH_UP", "scheduler.catch_up"),
              ("SHIKIGAMI_SINKS_REI_BASE_URL", "sinks.rei.base_url"),
              ("SHIKIGAMI_RUN_TIMEOUT_SECONDS", "worker.run_timeout_seconds")
            ],
      testCase "every declared key can be set from the environment" $
        sort (fmap snd boundVariables) @?= sort (fmap renderKey declaredKeys),
      testCase "with no source at all, the declared defaults are what a process gets" do
        agentsDirectory defaultAppConfig @?= "agents"
        -- Skip-missed is the deliberate behavior change on upgrade: waking late
        -- arms one future tick rather than replaying every minute of downtime.
        schedulerCatchUp defaultAppConfig @?= SkipMissed
        portNumber (httpPort defaultAppConfig) @?= 8080
        httpHost defaultAppConfig @?= "127.0.0.1"
        runTimeout defaultAppConfig @?= secondsToNominalDiffTime 300
        approvalDeadline defaultAppConfig @?= secondsToNominalDiffTime 900
        kafkaBroker defaultAppConfig @?= "127.0.0.1:9092"
        kafkaActivityTopic defaultAppConfig @?= "activity.v1"
        kafkaEventsTopic defaultAppConfig @?= "danwa.message-addressed.v1"
        kafkaStreamGroup defaultAppConfig @?= "shikigami-stream"
        kafkaEventsGroup defaultAppConfig @?= "shikigami-events"
        kafkaIncludeAgentActors defaultAppConfig @?= False
        queueNameToText (kafkaDeadLetterQueue defaultAppConfig) @?= "shikigami_stream_dead_letters"
        kawaBaseUrl defaultAppConfig @?= "http://localhost:8088"
        kawaSourceSegment defaultAppConfig @?= "shinzui/shikigami"
        kizashiBaseUrl defaultAppConfig @?= "http://localhost:8089"
        kizashiDefaultRecipient defaultAppConfig @?= "recipient:default"
        danwaBaseUrl defaultAppConfig @?= "http://localhost:8080"
        danwaAgentParticipant defaultAppConfig @?= "part_shikigami"
        -- Deliberately absent rather than pointing somewhere: rei has no HTTP
        -- surface, and a defaulted URL would turn "nowhere to send" into
        -- "connection refused to a host nobody chose".
        reiBaseUrl defaultAppConfig @?= Nothing
    ]

boundVariables :: [(Text, Text)]
boundVariables =
  [ (name, renderKey (bindingKey b))
  | b <- bindingsList environmentBindings,
    let EnvName name = bindingName b
  ]

-- ── Precedence ──────────────────────────────────────────────────────────────

precedenceTests :: TestTree
precedenceTests =
  testGroup
    "precedence"
    [ testCase "the environment beats a configuration file" do
        config <-
          resolveOrFail
            (optionsWith [] [])
            [yaml "file" "kafka:\n  broker: from-file:9092\n"]
            [("SHIKIGAMI_KAFKA_BROKER", "from-env:9092")]
        kafkaBroker config @?= "from-env:9092",
      testCase "a named command-line flag beats the environment" do
        config <-
          resolveOrFail
            (optionsWith [namedSource "--broker" kafkaBrokerKey "from-flag:9092"] [])
            []
            [("SHIKIGAMI_KAFKA_BROKER", "from-env:9092")]
        kafkaBroker config @?= "from-flag:9092",
      testCase "a --set override beats a named flag" do
        config <-
          resolveOrFail
            ( optionsWith
                [namedSource "--broker" kafkaBrokerKey "from-flag:9092"]
                [cliOverride kafkaBrokerKey "from-set:9092"]
            )
            []
            []
        kafkaBroker config @?= "from-set:9092",
      testCase "the last of several --config files wins" do
        config <-
          resolveOrFail
            (optionsWith [] [])
            [ yaml "first" "agents:\n  directory: first\n",
              yaml "second" "agents:\n  directory: second\n"
            ]
            []
        agentsDirectory config @?= "second",
      testCase "the last of several --set overrides wins" do
        config <-
          resolveOrFail
            (optionsWith [] [cliOverride agentsDirectoryKey "first", cliOverride agentsDirectoryKey "second"])
            []
            []
        agentsDirectory config @?= "second",
      testCase "an unset key keeps its declared default even when its neighbours are set" do
        config <- resolveOrFail (optionsWith [] []) [yaml "file" "kafka:\n  broker: only-this:9092\n"] []
        kafkaBroker config @?= "only-this:9092"
        kafkaActivityTopic config @?= "activity.v1",
      testCase "duration budgets resolve in YAML, environment, then CLI precedence" do
        config <-
          resolveOrFail
            ( optionsWith
                []
                [ cliOverride workerRunTimeoutSecondsKey "240",
                  cliOverride approvalDeadlineSecondsKey "840"
                ]
            )
            [ yaml
                "file"
                "worker:\n  run_timeout_seconds: 120\napproval:\n  deadline_seconds: 600\n"
            ]
            [ ("SHIKIGAMI_RUN_TIMEOUT_SECONDS", "180"),
              ("SHIKIGAMI_APPROVAL_DEADLINE_SECONDS", "720")
            ]
        runTimeout config @?= secondsToNominalDiffTime 240
        approvalDeadline config @?= secondsToNominalDiffTime 840
    ]

-- ── Strictness ──────────────────────────────────────────────────────────────

strictnessTests :: TestTree
strictnessTests =
  testGroup
    "strictness"
    [ testCase "an unknown key in a file is rejected rather than ignored" $
        exitCode (runWith (optionsWith [] []) [yaml "file" "kafka:\n  brokers: typo:9092\n"] [])
          @?= resolutionExitCode,
      -- The tempting alternative is to fall back to the environment's valid
      -- 8080. That would start a listener on a port nobody asked for.
      testCase "a malformed winning value is fatal and does not fall back" do
        let run = runWith (optionsWith [] [cliOverride httpPortKey "not-a-port"]) [] [("SHIKIGAMI_HTTP_PORT", "8080")]
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the port key and the accepted range:\n" <> Text.unpack (standardError run))
          ("http.port" `Text.isInfixOf` standardError run && "65535" `Text.isInfixOf` standardError run),
      testCase "a port outside 1-65535 is rejected at resolution time" $
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride httpPortKey bad]) [] []) @?= resolutionExitCode)
          ["0", "65536", "-1"],
      testCase "the boundary port is accepted" do
        config <- resolveOrFail (optionsWith [] [cliOverride httpPortKey "65535"]) [] []
        portNumber (httpPort config) @?= 65535,
      testCase "duration budgets reject non-positive and unsafe values" $
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride workerRunTimeoutSecondsKey bad]) [] []) @?= resolutionExitCode)
          ["0", "86401", "-1", "1.5"],
      testCase "duration budget boundaries are accepted" do
        low <- resolveOrFail (optionsWith [] [cliOverride workerRunTimeoutSecondsKey "1"]) [] []
        high <- resolveOrFail (optionsWith [] [cliOverride approvalDeadlineSecondsKey "86400"]) [] []
        runTimeout low @?= secondsToNominalDiffTime 1
        approvalDeadline high @?= secondsToNominalDiffTime 86_400,
      testCase "a source that could not be read exits with the source status" do
        let run = appConfigRun ServerRole (optionsWith [] []) (Left "config.yaml: does not exist") (emptyEnvironment [])
        exitCode run @?= sourceExitCode
        standardError run @?= "config.yaml: does not exist",
      testCase "a textual boolean from the environment decodes" do
        config <- resolveOrFail (optionsWith [] []) [] [("SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS", "true")]
        kafkaIncludeAgentActors config @?= True,
      testCase "an invalid dead-letter queue name is rejected at resolution time" do
        let run = runWith (optionsWith [] [cliOverride kafkaDeadLetterQueueKey "Not-A-PGMQ-Queue"]) [] []
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the queue key and grammar:\n" <> Text.unpack (standardError run))
          ("kafka.dead_letter.queue" `Text.isInfixOf` standardError run && "lowercase" `Text.isInfixOf` standardError run)
    ]

-- ── Per-role requirements ───────────────────────────────────────────────────

requirementTests :: TestTree
requirementTests =
  testGroup
    "role requirements"
    [ testCase "roles that open a database report the connection string as missing" $
        mapM_
          (\role -> fmap renderKey (missingRequirements role defaultAppConfig) @?= ["database.connection_string"])
          [WorkerRole, SchedulerRole, StreamConsumerRole, EventConsumerRole, AgentRunRole, MigrateRole],
      testCase "roles that open no database require nothing" $
        mapM_
          (\role -> missingRequirements role defaultAppConfig @?= [])
          [ServerRole, AdminRole, RunBehaviorRole],
      testCase "a supplied connection string satisfies the requirement" do
        config <- resolveOrFail (optionsWith [] []) [] [("PG_CONNECTION_STRING", "postgresql:///shikigami")]
        missingRequirements WorkerRole config @?= [],
      -- An empty string resolves successfully but cannot open anything, so it is
      -- treated as absent rather than as a value.
      testCase "an empty connection string does not satisfy the requirement" do
        config <- resolveOrFail (optionsWith [] []) [] [("PG_CONNECTION_STRING", "")]
        fmap renderKey (missingRequirements WorkerRole config) @?= ["database.connection_string"],
      testCase "a worker started without a connection string fails at configuration time" do
        let run = appConfigRun WorkerRole (optionsWith [] []) (Right []) (emptyEnvironment [])
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the binary and the key:\n" <> Text.unpack (standardError run))
          ( "shikigami-worker" `Text.isInfixOf` standardError run
              && "database.connection_string" `Text.isInfixOf` standardError run
          )
    ]

-- ── Diagnostics ─────────────────────────────────────────────────────────────

diagnosticTests :: TestTree
diagnosticTests =
  testGroup
    "diagnostics"
    [ -- Schema diagnostics must not need a source to exist, which is what makes
      -- --describe-config answerable in a container with nothing mounted.
      testCase "the schema diagnostics answer even when a source could not be read" $
        mapM_
          ( \mode -> do
              let run = appConfigRun ServerRole (diagnosticOptions mode) (Left "unreadable") (emptyEnvironment [])
              exitCode run @?= 0
              assertBool "schema output should not be empty" (not (Text.null (standardOutput run)))
          )
          [DescribeConfigText, DescribeConfigJson],
      testCase "every diagnostic mode exits zero and returns no configuration to run with" $
        mapM_
          ( \mode -> do
              let run = runWith (diagnosticOptions mode) [] []
              exitCode run @?= 0
              assertBool ("mode " <> show mode <> " printed nothing") (not (Text.null (standardOutput run)))
              assertBool ("mode " <> show mode <> " must not let the process continue") (not (hasConfig run))
          )
          [DescribeConfigText, DescribeConfigJson, ExplainText, ExplainJson, CheckConfig],
      testCase "--check-config says so plainly" $
        standardOutput (runWith (diagnosticOptions CheckConfig) [] []) @?= "configuration valid\n",
      testCase "a check of an invalid configuration fails with the resolution status" $
        exitCode (runWith (diagnosticOptions CheckConfig) [] [("SHIKIGAMI_HTTP_PORT", "no")])
          @?= resolutionExitCode,
      testCase "--explain-config names where a value came from" do
        let run = runWith (diagnosticOptions ExplainText) [] [("SHIKIGAMI_KAFKA_BROKER", "explained:9092")]
        assertBool
          ("the explanation should name the variable:\n" <> Text.unpack (standardOutput run))
          ("SHIKIGAMI_KAFKA_BROKER" `Text.isInfixOf` standardOutput run),
      testCase "schema and explanation expose both duration policies" do
        let schema = renderSchemaText appConfigSchema
            explained = standardOutput (runWith (diagnosticOptions ExplainText) [] [])
        mapM_
          ( \key -> do
              assertBool (Text.unpack key <> " missing from schema") (key `Text.isInfixOf` schema)
              assertBool (Text.unpack key <> " missing from explanation") (key `Text.isInfixOf` explained)
          )
          ["worker.run_timeout_seconds", "approval.deadline_seconds"],
      testCase "with no diagnostic, a valid configuration lets the process continue" do
        let run = runWith (optionsWith [] []) [] []
        exitCode run @?= 0
        standardOutput run @?= ""
        assertBool "a valid run must produce a configuration" (hasConfig run)
    ]

-- ── Secrecy ─────────────────────────────────────────────────────────────────

secrecyTests :: TestTree
secrecyTests =
  testGroup
    "secrecy"
    [ testCase "a planted connection string appears in no rendering, whatever supplied it" $
        mapM_
          assertNoLeak
          [ ("a configuration file", [yaml "file" ("database:\n  connection_string: " <> plantedBytes <> "\n")], [], []),
            ("the environment", [], [("PG_CONNECTION_STRING", planted)], []),
            ("a --set override", [], [], [cliOverride databaseConnectionStringKey planted])
          ],
      -- A failing resolution is the dangerous case: error renderings are where a
      -- raw value most easily escapes.
      testCase "a planted secret does not leak through a failing resolution" do
        let run =
              runWith
                (optionsWith [] [cliOverride databaseConnectionStringKey planted, cliOverride httpPortKey "not-a-port"])
                []
                []
        exitCode run @?= resolutionExitCode
        assertAbsent "the failure message" (standardError run),
      testCase "the schema itself never carries a value" do
        assertAbsent "the text schema" (renderSchemaText appConfigSchema)
        assertAbsent "the JSON schema" (renderSchemaJson appConfigSchema)
    ]

-- | A token no default, description, or key contains, so finding it anywhere is
-- unambiguous evidence of a leak.
planted :: Text
planted = "postgresql://user:s3cr3t-planted-token-42@db/shikigami"

plantedBytes :: ByteString
plantedBytes = "postgresql://user:s3cr3t-planted-token-42@db/shikigami"

-- | Resolve one source combination in every mode and prove the token is absent
-- from output, errors, and both resolution reports.
assertNoLeak :: (String, [Source], [(Text, Text)], [CliOverride]) -> IO ()
assertNoLeak (label, files, environment, sets) = do
  mapM_
    ( \mode -> do
        let run = runWith (optionsWith [] sets) {diagnosticMode = mode} files environment
        assertAbsent (label <> ", " <> show mode <> " stdout") (standardOutput run)
        assertAbsent (label <> ", " <> show mode <> " stderr") (standardError run)
    )
    [DescribeConfigText, DescribeConfigJson, ExplainText, ExplainJson, CheckConfig]
  let ResolveResult {report} = resolveAppConfig (optionsWith [] sets) files (emptyEnvironment environment)
  assertAbsent (label <> ", text report") (renderResolutionText report)
  assertAbsent (label <> ", JSON report") (renderResolutionJson report)

assertAbsent :: String -> Text -> IO ()
assertAbsent label rendered =
  assertBool
    (label <> " leaked the planted secret:\n" <> Text.unpack rendered)
    (not ("s3cr3t-planted-token-42" `Text.isInfixOf` rendered))

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- | Resolve under the server role — the role with no required keys — so a
-- precedence test is not also a requirement test.
resolveOrFail :: ConfigOptions -> [Source] -> [(Text, Text)] -> IO AppConfig
resolveOrFail options files environment =
  case configOf run of
    Just config -> pure config
    Nothing ->
      assertFailure
        ("expected a resolved configuration, got exit " <> show (exitCode run) <> ":\n" <> Text.unpack (standardError run))
  where
    run = runWith options files environment

runWith :: ConfigOptions -> [Source] -> [(Text, Text)] -> ConfigRun
runWith options files environment =
  appConfigRun ServerRole options (Right files) (emptyEnvironment environment)

-- | The environment source, built from an injected snapshot rather than the
-- real process environment, so a test never depends on the developer's shell.
emptyEnvironment :: [(Text, Text)] -> Source
emptyEnvironment values = environmentSource environmentBindings (snapshot values)

snapshot :: [(Text, Text)] -> EnvSnapshot
snapshot = envSnapshot

optionsWith :: [Source] -> [CliOverride] -> ConfigOptions
optionsWith sources sets =
  ConfigOptions
    { configPaths = [],
      namedSources = sources,
      overrides = sets,
      diagnosticMode = NoDiagnostic
    }

diagnosticOptions :: DiagnosticMode -> ConfigOptions
diagnosticOptions mode = (optionsWith [] []) {diagnosticMode = mode}

-- | The source a named flag such as @--broker@ contributes.
namedSource :: Text -> Key -> Text -> Source
namedSource spelling key value =
  case cliSources spelling [cliOverride key value] of
    [built] -> built
    other -> error ("one override should yield one source, got " <> show (length other))

-- | Parse YAML the way @--config PATH@ does, from bytes rather than a file.
yaml :: Text -> ByteString -> Source
yaml name bytes =
  either
    (\problems -> error ("test fixture " <> Text.unpack name <> " is not valid YAML: " <> show problems))
    id
    (decodeYamlSource (yamlSourceOptions name) bytes)

hasConfig :: ConfigRun -> Bool
hasConfig = maybe False (const True) . configOf

configOf :: ConfigRun -> Maybe AppConfig
configOf ConfigRun {resolved} = resolved
