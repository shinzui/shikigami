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
import Data.ByteString.Char8 qualified as ByteString
import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
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
import Shikigami.Agent.Approval (ApprovalChannel (ViaDanwa, ViaKizashi))
import Shikigami.Agent.Decl (delegationBudgetNatural)
import Shikigami.App.Config
import Shikigami.App.Config.Load
import Shikigami.PracticeReview.Capability (renderAttentionRecipientMap)
import Shikigami.Sink.Auth (TokenSource (..), credentialToken, matchesBearerHeader, staticTokenSource)
import Shikigami.Sink.Permission (SinkKind (..))
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
                "agents.strict",
                "approval.channel",
                "approval.deadline_seconds",
                "approval.require",
                "behavior.model",
                "behavior.provider",
                "conversation.idle_timeout_seconds",
                "credentials.providers.anthropic.api_key",
                "credentials.sinks.danwa.token",
                "credentials.sinks.kanmon.token",
                "credentials.sinks.kawa.token",
                "credentials.sinks.kizashi.token",
                "database.connection_string",
                "delegation.default_budget",
                "directory.file.path",
                "directory.mode",
                "directory.refresh_interval_seconds",
                "health.port",
                "http.host",
                "http.port",
                "http.request_max_bytes",
                "http.response_max_bytes",
                "kafka.activity.topic",
                "kafka.broker",
                "kafka.dead_letter.queue",
                "kafka.events.topic",
                "kafka.groups.events",
                "kafka.groups.stream",
                "kafka.include_agent_actors",
                "practice_review.attention_recipients",
                "scheduler.catch_up",
                "sinks.danwa.agent_participant",
                "sinks.danwa.base_url",
                "sinks.kanmon.base_url",
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
              ("SHIKIGAMI_AGENTS_STRICT", "agents.strict"),
              ("SHIKIGAMI_APPROVAL_CHANNEL", "approval.channel"),
              ("SHIKIGAMI_APPROVAL_DEADLINE_SECONDS", "approval.deadline_seconds"),
              ("SHIKIGAMI_APPROVAL_REQUIRE", "approval.require"),
              ("SHIKIGAMI_BEHAVIOR_MODEL", "behavior.model"),
              ("SHIKIGAMI_BEHAVIOR_PROVIDER", "behavior.provider"),
              ("SHIKIGAMI_CONVERSATION_IDLE_TIMEOUT_SECONDS", "conversation.idle_timeout_seconds"),
              ("SHIKIGAMI_DELEGATION_DEFAULT_BUDGET", "delegation.default_budget"),
              ("SHIKIGAMI_DIRECTORY_FILE_PATH", "directory.file.path"),
              ("SHIKIGAMI_DIRECTORY_MODE", "directory.mode"),
              ("SHIKIGAMI_DIRECTORY_REFRESH_INTERVAL_SECONDS", "directory.refresh_interval_seconds"),
              ("SHIKIGAMI_HEALTH_PORT", "health.port"),
              ("SHIKIGAMI_HTTP_HOST", "http.host"),
              ("SHIKIGAMI_HTTP_PORT", "http.port"),
              ("SHIKIGAMI_HTTP_REQUEST_MAX_BYTES", "http.request_max_bytes"),
              ("SHIKIGAMI_HTTP_RESPONSE_MAX_BYTES", "http.response_max_bytes"),
              ("SHIKIGAMI_KAFKA_ACTIVITY_TOPIC", "kafka.activity.topic"),
              ("SHIKIGAMI_KAFKA_BROKER", "kafka.broker"),
              ("SHIKIGAMI_KAFKA_DEAD_LETTER_QUEUE", "kafka.dead_letter.queue"),
              ("SHIKIGAMI_KAFKA_EVENTS_GROUP", "kafka.groups.events"),
              ("SHIKIGAMI_KAFKA_EVENTS_TOPIC", "kafka.events.topic"),
              ("SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS", "kafka.include_agent_actors"),
              ("SHIKIGAMI_KAFKA_STREAM_GROUP", "kafka.groups.stream"),
              ("SHIKIGAMI_KAWA_TOKEN", "credentials.sinks.kawa.token"),
              ("SHIKIGAMI_KANMON_TOKEN", "credentials.sinks.kanmon.token"),
              ("SHIKIGAMI_KIZASHI_TOKEN", "credentials.sinks.kizashi.token"),
              ("SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS", "practice_review.attention_recipients"),
              ("SHIKIGAMI_DANWA_TOKEN", "credentials.sinks.danwa.token"),
              ("SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT", "sinks.danwa.agent_participant"),
              ("SHIKIGAMI_SINKS_DANWA_BASE_URL", "sinks.danwa.base_url"),
              ("SHIKIGAMI_SINKS_KANMON_BASE_URL", "sinks.kanmon.base_url"),
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
        -- Lenient by default: upgrading must not turn a tolerated broken
        -- manifest into a failed deploy without an explicit configuration change.
        agentsStrict defaultAppConfig @?= False
        directorySettings defaultAppConfig @?= DirectoryDisabled
        delegationBudgetNatural (delegationBudget defaultAppConfig) @?= 16
        portNumber (httpPort defaultAppConfig) @?= 8080
        httpHost defaultAppConfig @?= "127.0.0.1"
        byteLimitBytes (httpRequestMaxBytes defaultAppConfig) @?= 8_388_608
        byteLimitBytes (httpResponseMaxBytes defaultAppConfig) @?= 8_388_608
        runTimeout defaultAppConfig @?= secondsToNominalDiffTime 300
        approvalRequiredSinks defaultAppConfig @?= Set.empty
        approvalChannel defaultAppConfig @?= ViaDanwa
        approvalDeadline defaultAppConfig @?= secondsToNominalDiffTime 900
        renderAttentionRecipientMap (practiceReviewAttentionRecipients defaultAppConfig) @?= ""
        kafkaBroker defaultAppConfig @?= "127.0.0.1:9092"
        kafkaActivityTopic defaultAppConfig @?= "activity.v1"
        kafkaEventsTopic defaultAppConfig @?= "danwa.message-addressed.v1"
        kafkaStreamGroup defaultAppConfig @?= "shikigami-stream"
        kafkaEventsGroup defaultAppConfig @?= "shikigami-events"
        kafkaIncludeAgentActors defaultAppConfig @?= False
        queueNameToText (kafkaDeadLetterQueue defaultAppConfig) @?= "shikigami_stream_dead_letters"
        kawaBaseUrl defaultAppConfig @?= "http://localhost:8088"
        kawaSourceSegment defaultAppConfig @?= "shinzui/shikigami"
        assertBool "kawa has no default credential" (isNothing (kawaToken defaultAppConfig))
        kizashiBaseUrl defaultAppConfig @?= "http://localhost:8089"
        kizashiDefaultRecipient defaultAppConfig @?= "recipient:default"
        assertBool "kizashi has no default credential" (isNothing (kizashiToken defaultAppConfig))
        kanmonBaseUrl defaultAppConfig @?= "http://localhost:8090"
        assertBool "Kanmon has no default credential" (isNothing (kanmonToken defaultAppConfig))
        danwaBaseUrl defaultAppConfig @?= "http://localhost:8080"
        danwaAgentParticipant defaultAppConfig @?= "part_shikigami"
        assertBool "danwa has no default credential" (isNothing (danwaToken defaultAppConfig))
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
        approvalDeadline config @?= secondsToNominalDiffTime 840,
      testCase "approval policy resolves in YAML, environment, then CLI precedence" do
        config <-
          resolveOrFail
            ( optionsWith
                []
                [ cliOverride approvalRequireKey "KizashiSignal, DanwaConversation",
                  cliOverride approvalChannelKey "danwa"
                ]
            )
            [yaml "file" "approval:\n  require: KawaDigest\n  channel: danwa\n"]
            [ ("SHIKIGAMI_APPROVAL_REQUIRE", "ReiAction"),
              ("SHIKIGAMI_APPROVAL_CHANNEL", "kizashi")
            ]
        approvalRequiredSinks config @?= Set.fromList [SKizashiSignal, SDanwaConversation]
        approvalChannel config @?= ViaDanwa,
      testCase "an empty approval requirement preserves auto-approval" do
        config <-
          resolveOrFail
            (optionsWith [] [])
            []
            [("SHIKIGAMI_APPROVAL_REQUIRE", ""), ("SHIKIGAMI_APPROVAL_CHANNEL", "kizashi")]
        approvalRequiredSinks config @?= Set.empty
        approvalChannel config @?= ViaKizashi,
      testCase "file directory settings resolve as one conditional value" do
        config <-
          resolveOrFail
            (optionsWith [] [])
            [yaml "file" "directory:\n  mode: file\n  file:\n    path: /etc/shikigami/principals.json\n"]
            [("SHIKIGAMI_DIRECTORY_REFRESH_INTERVAL_SECONDS", "7")]
        directorySettings config
          @?= DirectoryFile
            { path = "/etc/shikigami/principals.json",
              refreshInterval = secondsToNominalDiffTime 7
            }
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
      testCase "HTTP body limits reject values outside 1 KiB through 64 MiB" $
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride httpRequestMaxBytesKey bad]) [] []) @?= resolutionExitCode)
          ["1023", "67108865", "-1", "1.5"],
      testCase "HTTP body-limit boundaries are accepted" do
        low <- resolveOrFail (optionsWith [] [cliOverride httpRequestMaxBytesKey "1024"]) [] []
        high <- resolveOrFail (optionsWith [] [cliOverride httpResponseMaxBytesKey "67108864"]) [] []
        byteLimitBytes (httpRequestMaxBytes low) @?= 1_024
        byteLimitBytes (httpResponseMaxBytes high) @?= 67_108_864,
      testCase "duration budgets reject non-positive and unsafe values" $
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride workerRunTimeoutSecondsKey bad]) [] []) @?= resolutionExitCode)
          ["0", "86401", "-1", "1.5"],
      testCase "duration budget boundaries are accepted" do
        low <- resolveOrFail (optionsWith [] [cliOverride workerRunTimeoutSecondsKey "1"]) [] []
        high <- resolveOrFail (optionsWith [] [cliOverride approvalDeadlineSecondsKey "86400"]) [] []
        runTimeout low @?= secondsToNominalDiffTime 1
        approvalDeadline high @?= secondsToNominalDiffTime 86_400,
      testCase "approval policy rejects duplicates, unknown sink kinds, and unknown channels" do
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride approvalRequireKey bad]) [] []) @?= resolutionExitCode)
          ["KawaDigest,KawaDigest", "KawaDigest,Unknown", ","]
        exitCode (runWith (optionsWith [] [cliOverride approvalChannelKey "email"]) [] []) @?= resolutionExitCode,
      testCase "practice-review recipients reject noncanonical destinations and duplicate owner sets" do
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride practiceReviewAttentionRecipientsKey bad]) [] []) @?= resolutionExitCode)
          [ "target-owner=recipient:wrong",
            "target-owner=recipient_one,target-owner=recipient_two",
            "target-owner+triage=recipient_one,triage+target-owner=recipient_two"
          ],
      testCase "a malformed winning approval policy does not fall back" do
        let run =
              runWith
                (optionsWith [] [cliOverride approvalRequireKey "Unknown"])
                []
                [("SHIKIGAMI_APPROVAL_REQUIRE", "KawaDigest")]
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the key and every valid sink kind:\n" <> Text.unpack (standardError run))
          ( all
              (`Text.isInfixOf` standardError run)
              [ "approval.require",
                "KawaDigest",
                "KizashiSignal",
                "ReiAction",
                "DanwaConversation",
                "ChannelEgress"
              ]
          ),
      testCase "file directory mode requires a path" do
        let run = runWith (optionsWith [] [cliOverride directoryModeKey "file"]) [] []
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the missing file path:\n" <> Text.unpack (standardError run))
          ("directory.file.path" `Text.isInfixOf` standardError run),
      testCase "directory refresh interval uses the bounded duration decoder" $
        mapM_
          ( \bad ->
              exitCode
                ( runWith
                    ( optionsWith
                        []
                        [ cliOverride directoryModeKey "file",
                          cliOverride directoryFilePathKey "/tmp/principals.json",
                          cliOverride directoryRefreshIntervalSecondsKey bad
                        ]
                    )
                    []
                    []
                )
                @?= resolutionExitCode
          )
          ["0", "86401", "-1", "1.5"],
      testCase "delegation budgets are bounded before runtime" do
        low <- resolveOrFail (optionsWith [] [cliOverride delegationBudgetKey "0"]) [] []
        high <- resolveOrFail (optionsWith [] [cliOverride delegationBudgetKey "1000"]) [] []
        delegationBudgetNatural (delegationBudget low) @?= 0
        delegationBudgetNatural (delegationBudget high) @?= 1000
        mapM_
          (\bad -> exitCode (runWith (optionsWith [] [cliOverride delegationBudgetKey bad]) [] []) @?= resolutionExitCode)
          ["1001", "-1", "1.5"],
      testCase "a source that could not be read exits with the source status" do
        let run = appConfigRun AdminRole (optionsWith [] []) (Left "config.yaml: does not exist") (emptyEnvironment [])
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
          [ServerRole, WorkerRole, SchedulerRole, StreamConsumerRole, EventConsumerRole, AgentRunRole, MigrateRole],
      testCase "roles that open no database require nothing" $
        mapM_
          (\role -> missingRequirements role defaultAppConfig @?= [])
          [AdminRole, RunBehaviorRole],
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
          ),
      -- The server joined the database list when its readiness probe started
      -- pinging PostgreSQL. Without this, a server started with no connection
      -- string binds its socket and then fails every readiness probe forever,
      -- which reads as a broken deploy rather than a missing setting.
      testCase "a server started without a connection string fails at configuration time" do
        let run = appConfigRun ServerRole (optionsWith [] []) (Right []) (emptyEnvironment [])
        exitCode run @?= resolutionExitCode
        assertBool
          ("the failure should name the binary and the key:\n" <> Text.unpack (standardError run))
          ( "shikigami-server" `Text.isInfixOf` standardError run
              && "database.connection_string" `Text.isInfixOf` standardError run
          ),
      -- The four worker processes routinely run on one host, so a shared probe
      -- default would make three of them fail to bind. Pinning the distinctness
      -- rather than the numbers alone is what keeps a future role from being
      -- given a port that is already taken.
      testCase "every probe-serving role gets its own default port" do
        fmap portNumber (defaultHealthPort WorkerRole) @?= Just 8091
        fmap portNumber (defaultHealthPort SchedulerRole) @?= Just 8092
        fmap portNumber (defaultHealthPort StreamConsumerRole) @?= Just 8093
        fmap portNumber (defaultHealthPort EventConsumerRole) @?= Just 8094
        let assigned = [portNumber port | role <- [minBound .. maxBound], Just port <- [defaultHealthPort role]]
        -- Distinctness is the property that matters; the numbers above are just
        -- which distinct ones. @nub@ is not imported, so compare against the
        -- sorted list with adjacent duplicates dropped.
        sort assigned @?= [8091, 8092, 8093, 8094]
        dedupe (sort assigned) @?= sort assigned,
      testCase "roles with no listener of their own get no probe port" $
        mapM_
          (\role -> fmap portNumber (defaultHealthPort role) @?= Nothing)
          [ServerRole, AdminRole, RunBehaviorRole, AgentRunRole, MigrateRole],
      testCase "an unset health.port leaves each role on its own default" $
        fmap portNumber (healthPortFor WorkerRole defaultAppConfig) @?= Just 8091,
      testCase "a configured health.port overrides the role default" do
        config <- resolveOrFail (optionsWith [] []) [] [("SHIKIGAMI_HEALTH_PORT", "9100")]
        fmap portNumber (healthPortFor WorkerRole config) @?= Just 9100,
      -- Resolving fine and then being ignored is the same thing that happens to
      -- kafka.broker on the scheduler: one declaration serves every binary.
      testCase "a configured health.port does not give a listener to a role without one" do
        config <- resolveOrFail (optionsWith [] []) [] [("SHIKIGAMI_HEALTH_PORT", "9100")]
        fmap portNumber (healthPortFor ServerRole config) @?= Nothing
    ]

-- | Drop adjacent duplicates from a sorted list.
dedupe :: (Eq a) => [a] -> [a]
dedupe (x : y : rest) | x == y = dedupe (y : rest)
dedupe (x : rest) = x : dedupe rest
dedupe [] = []

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
              let run = appConfigRun AdminRole (diagnosticOptions mode) (Left "unreadable") (emptyEnvironment [])
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
      testCase "schema and explanation expose the duration policies" do
        let schema = renderSchemaText appConfigSchema
            explained = standardOutput (runWith (diagnosticOptions ExplainText) [] [])
        mapM_
          ( \key -> do
              assertBool (Text.unpack key <> " missing from schema") (key `Text.isInfixOf` schema)
              assertBool (Text.unpack key <> " missing from explanation") (key `Text.isInfixOf` explained)
          )
          ["worker.run_timeout_seconds", "approval.require", "approval.channel", "approval.deadline_seconds", "directory.refresh_interval_seconds"],
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
      testCase "a planted sink token appears in no rendering, whatever supplied it" $
        mapM_
          assertNoLeak
          [ ("a sink token in a configuration file", [yaml "file" ("credentials:\n  sinks:\n    kawa:\n      token: " <> plantedTokenBytes <> "\n")], [], []),
            ("a sink token in the environment", [], [("SHIKIGAMI_KAWA_TOKEN", plantedToken)], []),
            ("a sink token in a --set override", [], [], [cliOverride kawaTokenKey plantedToken]),
            ("the Kanmon token in a configuration file", [yaml "file" ("credentials:\n  sinks:\n    kanmon:\n      token: " <> plantedTokenBytes <> "\n")], [], []),
            ("the Kanmon token in the environment", [], [("SHIKIGAMI_KANMON_TOKEN", plantedToken)], []),
            ("the Kanmon token in a --set override", [], [], [cliOverride kanmonTokenKey plantedToken])
          ],
      testCase "an opaque token source renders and compares no plaintext at its public boundary" do
        config <- resolveOrFail (optionsWith [] []) [] [("SHIKIGAMI_KAWA_TOKEN", plantedToken)]
        case kawaToken config of
          Nothing -> assertFailure "the configured kawa token did not resolve"
          Just secret -> do
            let token = credentialToken secret
            assertBool "the exact bearer header should match" (matchesBearerHeader token ("Bearer " <> ByteString.pack (Text.unpack plantedToken)))
            assertBool "a different bearer header must not match" (not (matchesBearerHeader token "Bearer wrong"))
            fetched <- fetchToken (staticTokenSource token)
            case fetched of
              Left _ -> assertFailure "a static token source failed"
              Right fetchedToken -> assertBool "the fetched token should remain usable without rendering" (matchesBearerHeader fetchedToken ("Bearer " <> ByteString.pack (Text.unpack plantedToken))),
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

plantedToken :: Text
plantedToken = "sink-s3cr3t-planted-token-42"

plantedTokenBytes :: ByteString
plantedTokenBytes = "sink-s3cr3t-planted-token-42"

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

-- | Resolve under the admin role — one of the two roles with no required keys —
-- so a precedence test is not also a requirement test. This was the server role
-- until @shikigami-server@'s readiness probe started pinging PostgreSQL and the
-- server acquired a required connection string.
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
  appConfigRun AdminRole options (Right files) (emptyEnvironment environment)

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
