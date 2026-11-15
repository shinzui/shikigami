module Shikigami.AuthoritySpec (tests) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow (WorkflowId (..))
import Kikan.En.Action qualified as Kikan
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Authority
import Shikigami.Authority.KikanEn (KikanEnMapping (..), UnmappedAction (..), toAgentAction)
import Shikigami.Record
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Authority"
    [ vocabularyTests,
      portTests,
      recordedTests,
      kikanMappingTests
    ]

principal :: Principal
principal = declarationCoordinate "agent_01h000000000000000triage"

connect :: Action
connect = either (error . Text.unpack) id (connectProviderAction "workspace.read" "v1")

invoke :: Action
invoke = either (error . Text.unpack) id (invokeToolAction "shikigami.workspace" "1" "admit-sha256-abc")

output :: Text -> NonEmpty Text -> Action
output kind segments =
  either (error . Text.unpack) id (EmitOutput <$> mkOutputKind kind <*> mkOutputTarget segments)

vocabularyTests :: TestTree
vocabularyTests =
  testGroup
    "vocabulary"
    [ testCase "every action has a stable tag and a bounded resource" do
        actionTag connect @?= "use_capability"
        actionTag (output "kizashi.signal" ("person:nadeem" :| [])) @?= "emit_output"
        actionResource connect @?= "capability_provider:workspace.read@v1"
        actionResource invoke @?= "capability_tool:shikigami.workspace@1/admit-sha256-abc"
        actionResource (output "channel.egress" ("slack" :| ["C123"])) @?= "channel.egress:slack/C123"
        assertBool "resources stay bounded" (all ((<= 400) . Text.length . actionResource) [connect, invoke]),
      testCase "targets refuse what Kikan-En would refuse" do
        assertBool "uppercase capability id" (isLeft (mkCapabilityTarget "Workspace" "v1"))
        assertBool "consecutive dots" (isLeft (mkCapabilityTarget "a..b" "v1"))
        assertBool "reserved revision character" (isLeft (mkCapabilityTarget "a" "v@1"))
        assertBool "whitespace tool name" (isLeft (mkToolName "read file"))
        assertBool "five target segments" (isLeft (mkOutputTarget ("a" :| ["b", "c", "d", "e"])))
        assertBool "undotted output kind" (isLeft (mkOutputKind "kizashi"))
    ]

portTests :: TestTree
portTests =
  testGroup
    "port"
    [ testCase "deny-all refuses every action and names no source" do
        result <- denyAll.decide principal connect
        result @?= Left (AuthorityUnavailable "per-action authorization is not configured")
        denyAll.source @?= NoAuthority,
      testCase "the test fixture allows and echoes the action" do
        result <- allowAllForTests.decide principal invoke
        fmap (.action) result @?= Right invoke
    ]

recordedTests :: TestTree
recordedTests =
  testGroup
    "recorded"
    [ testCase "every decision appends exactly one event, refusals included" do
        (record, events) <- memoryRecord
        let installed = recorded record unspecifiedTier denyAll
        _ <- installed.decide principal connect
        _ <- installed.decide principal invoke
        observed <- events
        length observed @?= 2
        case observed of
          [first', _] -> do
            let (kind, payload) = recordEntry first'.entry
            recordKindText kind @?= "authority.decided"
            field "decision" payload @?= Just "unavailable"
            field "decidedBy" payload @?= Just "none"
            field "resource" payload @?= Just "capability_provider:workspace.read@v1"
            first'.principal @?= "agent_01h000000000000000triage"
            first'.run @?= Nothing
          _ -> assertFailure "expected two events",
      testCase "an allow records the reference and the decision passes through" do
        (record, events) <- memoryRecord
        result <- (recorded record unspecifiedTier allowAllForTests).decide principal invoke
        fmap (.action) result @?= Right invoke
        observed <- events
        fmap (field "decision" . snd . recordEntry . (.entry)) observed @?= [Just "allowed"]
        fmap (field "reference" . snd . recordEntry . (.entry)) observed @?= [Just "request_test"],
      testCase "a failed append turns an allow into a refusal" do
        let failing = ActionRecord {append = \_ -> pure (Left (RecordStoreUnavailable "database stopped"))}
        result <- (recorded failing unspecifiedTier allowAllForTests).decide principal invoke
        case result of
          Left (AuthorityUnavailable detail) -> assertBool "names the record" ("action record unavailable" `Text.isPrefixOf` detail)
          other -> assertFailure ("expected a refusal, got " <> show other),
      testCase "scoping to a run attaches the run and agent to recorded events" do
        (record, events) <- memoryRecord
        agent <- either (fail . Text.unpack) pure (mkAgentName "triage-note")
        let scoped = scopeToRun (Just (WorkflowId "run-1")) agent (recorded record unspecifiedTier denyAll)
        _ <- scoped.decide principal connect
        observed <- events
        fmap (.run) observed @?= [Just (WorkflowId "run-1")]
        fmap (.agent) observed @?= [Just agent],
      testCase "an observer sees the decision without changing it" do
        (record, events) <- memoryRecord
        let observed = observeDecisions (\_ _ _ -> record.append (sampleEvent "observer.saw") >> pure ()) allowAllForTests
        result <- observed.decide principal connect
        fmap (.action) result @?= Right connect
        fmap (recordKindText . fst . recordEntry . (.entry)) <$> events >>= (@?= ["observer.saw"])
    ]

kikanMappingTests :: TestTree
kikanMappingTests =
  testGroup
    "Kikan-En mapping"
    [ testCase "capability operations map one to one" do
        fmap Kikan.actionTag (mapped connect) @?= Right "connect_capability"
        fmap Kikan.actionTag (mapped invoke) @?= Right "invoke_capability_tool"
        fmap (Kikan.canonicalResourceText . Kikan.actionResource) (mapped invoke) @?= Right "capability_tool:shikigami.workspace@1/admit-sha256-abc",
      testCase "each Kikan output kind maps to its action" do
        fmap Kikan.actionTag (mapped (output "kawa.digest" ("ticket" :| ["ticket.received"]))) @?= Right "dispatch_kawa"
        fmap (Kikan.canonicalResourceText . Kikan.actionResource) (mapped (output "kawa.digest" ("ticket" :| ["ticket.received"]))) @?= Right "kawa_source:shinzui/shikigami"
        fmap Kikan.actionTag (mapped (output "kizashi.signal" ("person-nadeem" :| []))) @?= Right "dispatch_kizashi"
        fmap Kikan.actionTag (mapped (output "rei.action" ("intention_1" :| []))) @?= Right "act_on_intention"
        fmap Kikan.actionTag (mapped (output "danwa.conversation" ("thread-1" :| []))) @?= Right "attach_danwa"
        fmap Kikan.actionTag (mapped (output "channel.egress" ("slack" :| ["C123"]))) @?= Right "dispatch_channel",
      testCase "an output Kikan-En has no action for is unmapped, never substituted" do
        case mapped (output "local.report" ("report" :| [])) of
          Left NoKikanAction {} -> pure ()
          other -> assertFailure ("expected NoKikanAction, got " <> show other)
        case mapped (output "channel.egress" ("slack" :| [])) of
          Left NoKikanAction {} -> pure ()
          other -> assertFailure ("a malformed channel target must not map: " <> show other),
      testCase "a target Kikan-En rejects is an invalid target" do
        case mapped (output "kizashi.signal" ("person:nadeem" :| [])) of
          Left InvalidKikanTarget {} -> pure ()
          other -> assertFailure ("expected InvalidKikanTarget, got " <> show other)
    ]
  where
    mapped = toAgentAction KikanEnMapping {kawaSource = activityCoordinate "shinzui/shikigami"} (UTCTime (fromGregorian 2026 11 15) 0)

field :: Text -> Value -> Maybe Text
field name = \case
  Object object -> case KeyMap.lookup (Key.fromText name) object of
    Just (String value) -> Just value
    _ -> Nothing
  _ -> Nothing

sampleEvent :: Text -> RecordEvent
sampleEvent kindText =
  RecordEvent
    { at = UTCTime (fromGregorian 2026 11 15) 0,
      run = Nothing,
      principal = "agent_test",
      tier = unspecifiedTier,
      agent = Nothing,
      entry = either (error . show) id (mkRecordEntry (either (error . Text.unpack) id (mkRecordKind kindText)) Null)
    }
