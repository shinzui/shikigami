-- | Every worker executable has a working command line.
--
-- These are smoke tests in the literal sense: they prove each binary's parser is
-- reachable, renders @--help@, names itself in the output, and accepts its
-- documented options. That is exactly the class of breakage a package split or a
-- configuration migration causes — an executable wired to the wrong parser, or
-- one whose options were dropped in the move — and it is invisible to the type
-- checker because every parser has the same type.
--
-- Since the move to resolved configuration, two more things are worth asserting.
-- The operator-facing flags now target declared configuration keys rather than
-- private parser values, so a flag that was silently dropped in that rewrite
-- would still compile; and every role must offer the same five diagnostic modes,
-- because an operator who learns them on one binary should not find them missing
-- on another.
--
-- They run the parser purely with @execParserPure@ rather than executing a built
-- binary, so they are fast, need no build-tool dependency, and can assert on the
-- rendered help text.
module Shikigami.Workers.CommandSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Options.Applicative
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config
import Shikigami.App.Config.Load (ConfigRun (..), appConfigRun)
import Shikigami.Workers.Command
  ( RoleInfo (..),
    consumeEventsRoleInfo,
    consumeStreamRoleInfo,
    schedulerRoleInfo,
    workerRoleInfo,
    workerRoles,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | The options every configurable executable offers, whatever its role.
configurationFlags :: [String]
configurationFlags =
  [ "--config",
    "--set",
    "--describe-config",
    "--describe-config-json",
    "--explain-config",
    "--explain-config-json",
    "--check-config"
  ]

tests :: TestTree
tests =
  testGroup
    "worker command lines"
    [ testCase "every worker executable renders --help" $
        mapM_
          ( \info -> do
              let rendered = helpTextOf info
              assertBool
                (binaryName info <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          workerRoles,
      -- The one-off roles moved to shikigami-agent; see
      -- "Shikigami.Agent.CommandSpec". Their absence here is the assertion that
      -- they did not stay behind and quietly keep linking Kafka and PGMQ.
      testCase "the four worker roles are named exactly once each" $
        fmap binaryName workerRoles
          @?= [ "shikigami-worker",
                "shikigami-scheduler",
                "shikigami-consume-stream",
                "shikigami-consume-events"
              ],
      testCase "each binary is wired to the role whose requirements it must meet" $
        fmap role workerRoles
          @?= [ WorkerRole,
                SchedulerRole,
                StreamConsumerRole,
                EventConsumerRole
              ],
      testCase "every worker executable offers the same configuration and diagnostic options" $
        mapM_ (`assertHasAll` configurationFlags) workerRoles,
      testCase "the worker keeps its downstream options" $
        assertHasAll
          workerRoleInfo
          ["--agents", "--kawa-url", "--kizashi-url", "--danwa-url", "--danwa-agent"],
      testCase "the scheduler keeps its agents directory option" $
        assertHasAll schedulerRoleInfo ["--agents"],
      testCase "the stream consumer keeps its topic and feedback-guard options" $
        assertHasAll
          consumeStreamRoleInfo
          ["--agents", "--broker", "--topic", "--group", "--include-agent-actors"],
      testCase "the event consumer keeps its topic and group options" $
        assertHasAll
          consumeEventsRoleInfo
          ["--agents", "--broker", "--topic", "--group"],
      testCase "each downstream flag names the configuration key it sets" do
        let rendered = helpTextOf workerRoleInfo
        mapM_
          ( \key ->
              assertBool
                ("shikigami-worker help does not name " <> key <> ":\n" <> rendered)
                (key `isInfixOf` rendered)
          )
          [ "agents.directory",
            "sinks.kawa.base_url",
            "sinks.kizashi.base_url",
            "sinks.danwa.base_url",
            "sinks.danwa.agent_participant"
          ],
      testCase "the two consumers aim their identically-spelled flags at different keys" do
        let streamHelp = helpTextOf consumeStreamRoleInfo
            eventsHelp = helpTextOf consumeEventsRoleInfo
        assertBool
          ("consume-stream --topic must set kafka.activity.topic:\n" <> streamHelp)
          ("kafka.activity.topic" `isInfixOf` streamHelp)
        assertBool
          ("consume-events --topic must set kafka.events.topic:\n" <> eventsHelp)
          ("kafka.events.topic" `isInfixOf` eventsHelp)
        assertBool
          ("consume-stream --group must set kafka.groups.stream:\n" <> streamHelp)
          ("kafka.groups.stream" `isInfixOf` streamHelp)
        assertBool
          ("consume-events --group must set kafka.groups.events:\n" <> eventsHelp)
          ("kafka.groups.events" `isInfixOf` eventsHelp),
      resolutionTests
    ]

-- | The flags actually reach the configuration they claim to.
--
-- The help-text cases above prove a flag exists and names a key. They cannot
-- prove it is wired to that key: @namedOption@ takes the spelling and the target
-- key as separate arguments, so a copy-paste that points @--kizashi-url@ at
-- @sinks.kawa.base_url@ produces perfect help text and the wrong deployment.
-- These cases run the real parser and then the real resolver, with an injected
-- environment so they do not depend on the developer's shell.
resolutionTests :: TestTree
resolutionTests =
  testGroup
    "resolution through the real parser"
    [ testCase "every worker flag lands on the setting it names" do
        config <-
          resolveArgs
            workerRoleInfo
            [ "--agents",
              "/srv/agents",
              "--kawa-url",
              "http://kawa.internal",
              "--kizashi-url",
              "http://kizashi.internal",
              "--danwa-url",
              "http://danwa.internal",
              "--danwa-agent",
              "part_from_flag"
            ]
        agentsDirectory config @?= "/srv/agents"
        kawaBaseUrl config @?= "http://kawa.internal"
        kizashiBaseUrl config @?= "http://kizashi.internal"
        danwaBaseUrl config @?= "http://danwa.internal"
        danwaAgentParticipant config @?= "part_from_flag",
      testCase "the stream consumer's flags land on the activity-stream settings" do
        config <-
          resolveArgs
            consumeStreamRoleInfo
            ["--broker", "b:9092", "--topic", "activity.test", "--group", "stream-test", "--include-agent-actors"]
        kafkaBroker config @?= "b:9092"
        kafkaActivityTopic config @?= "activity.test"
        kafkaStreamGroup config @?= "stream-test"
        kafkaIncludeAgentActors config @?= True
        -- The event consumer's settings must be untouched by the stream
        -- consumer's identically-spelled flags.
        kafkaEventsTopic config @?= kafkaEventsTopic defaultAppConfig
        kafkaEventsGroup config @?= kafkaEventsGroup defaultAppConfig,
      testCase "the event consumer's flags land on the integration-event settings" do
        config <- resolveArgs consumeEventsRoleInfo ["--topic", "events.test", "--group", "events-test"]
        kafkaEventsTopic config @?= "events.test"
        kafkaEventsGroup config @?= "events-test"
        kafkaActivityTopic config @?= kafkaActivityTopic defaultAppConfig
        kafkaStreamGroup config @?= kafkaStreamGroup defaultAppConfig,
      testCase "omitting the feedback-guard switch leaves the guard on" do
        config <- resolveArgs consumeStreamRoleInfo ["--broker", "b:9092"]
        kafkaIncludeAgentActors config @?= False,
      testCase "a --set override beats the equivalent named flag" do
        config <- resolveArgs workerRoleInfo ["--agents", "/from-flag", "--set", "agents.directory=/from-set"]
        agentsDirectory config @?= "/from-set"
    ]

-- | Parse the given arguments with a role's real parser, then resolve the
-- sources it produced.
--
-- The environment is injected rather than read from the process, so these cases
-- do not depend on the developer's shell. It supplies only a connection string,
-- because every worker role but @run-behavior@ refuses to start without one and
-- these cases are about where the /other/ values come from.
resolveArgs :: RoleInfo -> [String] -> IO AppConfig
resolveArgs info args =
  case execParserPure defaultPrefs (parserInfo info) args of
    Success (_, options) ->
      let environment =
            environmentSource
              environmentBindings
              (envSnapshot [("PG_CONNECTION_STRING", "postgresql:///shikigami-test")])
          run = appConfigRun (role info) options (Right []) environment
       in case resolved run of
            Just config -> pure config
            Nothing ->
              assertFailure
                ( binaryName info
                    <> ": expected a resolved configuration, got exit "
                    <> show (exitCode run)
                    <> ":\n"
                    <> Text.unpack (standardError run)
                )
    Failure failure ->
      let (message, _) = renderFailure failure (binaryName info)
       in assertFailure (binaryName info <> ": arguments did not parse:\n" <> message)
    CompletionInvoked _ -> assertFailure "unexpected completion invocation"

-- | Assert the rendered help mentions every flag the command is documented to take.
assertHasAll :: RoleInfo -> [String] -> IO ()
assertHasAll info flags =
  mapM_
    ( \flag ->
        assertBool
          (binaryName info <> ": --help does not mention " <> flag <> ":\n" <> rendered)
          (flag `isInfixOf` rendered)
    )
    flags
  where
    rendered = helpTextOf info

-- | Run a parser on @--help@ and return what it printed.
--
-- @--help@ always ends in a parser 'Failure'; the help text is the failure's
-- rendering. A 'Success' would mean the parser did not understand @--help@ at
-- all, which is itself the bug these tests look for.
helpTextOf :: RoleInfo -> String
helpTextOf info =
  case execParserPure defaultPrefs (parserInfo info) ["--help"] of
    Failure failure -> let (message, _) = renderFailure failure (binaryName info) in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"
