-- | The distribution's two consumer roles have working command lines, their
-- identically spelled flags land on different keys, and the Kafka transport
-- gives up on a failure reconnecting cannot repair (plan 135, M5; these cases
-- moved from the stock worker suite with the roles).
module Kikan.Shikigami.Binding.IntakeSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Kafka.Consumer (RdKafkaRespErrT (RdKafkaRespErrAllBrokersDown, RdKafkaRespErrFatal, RdKafkaRespErrSaslAuthenticationFailed))
import Kafka.Types (KafkaError (..))
import Kikan.Shikigami.Binding.Intake (kafkaReconnectAllowed)
import Kikan.Shikigami.Binding.Intake.Role (consumeEventsRoleInfo, consumeStreamRoleInfo)
import Options.Applicative
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config
import Shikigami.App.Config.Load (ConfigRun (..), appConfigRun)
import Shikigami.App.Role (RoleInfo (..))
import Shikigami.Trigger.Stream (IncludeAgentActors (..))
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "intake"
    [ testCase "Kafka deterministic and authentication failures do not reconnect forever" do
        map kafkaReconnectAllowed [KafkaBadConfiguration, KafkaBadSpecification "invalid", KafkaResponseError RdKafkaRespErrFatal, KafkaResponseError RdKafkaRespErrSaslAuthenticationFailed] @?= replicate 4 False
        kafkaReconnectAllowed (KafkaResponseError RdKafkaRespErrAllBrokersDown) @?= True,
      testCase "the consumers are the distribution's, wired to the consumer roles" do
        fmap (.binaryName) roles @?= ["kikan-shikigami-consume-stream", "kikan-shikigami-consume-events"]
        fmap (.role) roles @?= [StreamConsumerRole, EventConsumerRole],
      testCase "each consumer renders --help, reports its version and offers the diagnostic options" $
        mapM_
          ( \info -> do
              assertBool (info.binaryName <> ": no usage line") ("Usage:" `isInfixOf` helpTextOf info)
              assertHasAll info ["--config", "--set", "--describe-config", "--explain-config", "--check-config"]
              assertVersion info
          )
          roles,
      testCase "the stream consumer keeps its topic and feedback-guard options" $
        assertHasAll stream ["--agents", "--broker", "--topic", "--group", "--include-agent-actors"],
      testCase "the event consumer keeps its topic and group options" $
        assertHasAll events ["--agents", "--broker", "--topic", "--group"],
      testCase "the two consumers aim their identically-spelled flags at different keys" do
        assertHasAll stream ["kafka.activity.topic", "kafka.groups.stream"]
        assertHasAll events ["kafka.events.topic", "kafka.groups.events"],
      testCase "the stream consumer's flags land on the activity-stream settings" do
        config <- resolveArgs stream ["--broker", "b:9092", "--topic", "activity.test", "--group", "stream-test", "--include-agent-actors"]
        config.kafkaBroker @?= "b:9092"
        config.kafkaActivityTopic @?= "activity.test"
        config.kafkaStreamGroup @?= "stream-test"
        config.kafkaIncludeAgentActors @?= IncludeAgentActors
        config.kafkaEventsTopic @?= defaultAppConfig.kafkaEventsTopic
        config.kafkaEventsGroup @?= defaultAppConfig.kafkaEventsGroup,
      testCase "the event consumer's flags land on the integration-event settings" do
        config <- resolveArgs events ["--topic", "events.test", "--group", "events-test"]
        config.kafkaEventsTopic @?= "events.test"
        config.kafkaEventsGroup @?= "events-test"
        config.kafkaActivityTopic @?= defaultAppConfig.kafkaActivityTopic
        config.kafkaStreamGroup @?= defaultAppConfig.kafkaStreamGroup,
      testCase "omitting the feedback-guard switch leaves the guard on" do
        config <- resolveArgs stream ["--broker", "b:9092"]
        config.kafkaIncludeAgentActors @?= ExcludeAgentActors
    ]
  where
    stream = consumeStreamRoleInfo []
    events = consumeEventsRoleInfo []
    roles = [stream, events]

-- | Parse with a role's real parser, then resolve with an injected
-- environment that supplies only a connection string.
resolveArgs :: RoleInfo -> [String] -> IO AppConfig
resolveArgs info args =
  case execParserPure defaultPrefs info.parserInfo args of
    Success (_, options) ->
      let environment = environmentSource environmentBindings (envSnapshot [("PG_CONNECTION_STRING", "postgresql:///shikigami-test")])
          run = appConfigRun info.role options (Right []) environment
       in case run.resolved of
            Just config -> pure config
            Nothing -> assertFailure (info.binaryName <> ": exit " <> show run.exitCode <> ":\n" <> Text.unpack run.standardError)
    Failure failure -> assertFailure (fst (renderFailure failure info.binaryName))
    CompletionInvoked _ -> assertFailure "unexpected completion invocation"

assertHasAll :: RoleInfo -> [String] -> IO ()
assertHasAll info flags =
  mapM_ (\flag -> assertBool (info.binaryName <> ": --help does not mention " <> flag <> ":\n" <> rendered) (flag `isInfixOf` rendered)) flags
  where
    rendered = helpTextOf info

helpTextOf :: RoleInfo -> String
helpTextOf info = case execParserPure defaultPrefs info.parserInfo ["--help"] of
  Failure failure -> fst (renderFailure failure info.binaryName)
  Success _ -> "unexpected success: the parser did not handle --help"
  CompletionInvoked _ -> "unexpected completion invocation"

assertVersion :: RoleInfo -> IO ()
assertVersion info = case execParserPure defaultPrefs info.parserInfo ["--version"] of
  Failure failure -> do
    let (message, exitCode) = renderFailure failure info.binaryName
    exitCode @?= ExitSuccess
    assertBool ("version does not name the executable: " <> message) (info.binaryName `isInfixOf` message)
  _ -> assertFailure "--version did not exit through optparse-applicative"
