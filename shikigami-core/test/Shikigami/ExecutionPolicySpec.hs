module Shikigami.ExecutionPolicySpec (tests) where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Control.Lens ((%~), (&), (.~))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Shikigami.Execution.Policy
import Shikigami.Execution.Transcript
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionPolicy"
    [ testCase "technical execution workflow identity has a stable separator-safe vector" do
        let workflow = executionWorkflowId (ExecutionId "execution:fixture")
        workflow.unWorkflowId @?= "89a70fa2-523e-5bf7-908c-2bdeb675badb"
        mkWorkflowId workflow.unWorkflowId @?= Right workflow,
      testCase "historical tool bindings retain unknown invoice cost and identical JSON" do
        let legacy = "{\"name\":\"observe\",\"revision\":\"1\",\"schemaDigest\":\"schema-digest\",\"recovery\":\"RepeatableObservation\"}"
        Aeson.eitherDecode @ToolBinding legacy @?= Right binding
        Aeson.eitherDecode @Aeson.Value legacy @?= Right (Aeson.toJSON binding)
        assertBool "a zero-invoice declaration changes immutable scope" (toolScopeDigest binding /= toolScopeDigest (binding & #invoiceCost .~ NoInvoiceCost)),
      testCase "old policy bytes and empty snapshots keep their digest inputs" do
        let policy = defaultHarnessPolicy
        Aeson.eitherDecode (Aeson.encode policy) @?= Right policy
        case Aeson.toJSON policy of
          Aeson.Object fields -> assertBool "absent extension omitted" (not (KeyMap.member "summaryTokens" fields))
          _ -> assertFailure "expected object"
        Aeson.eitherDecode @HarnessOverrides "{}" @?= Right emptyHarnessOverrides
        assertBool "unknown policy options refused" (isLeft (Aeson.eitherDecode @HarnessOverrides "{\"grantTool\":true}")),
      testCase "declaration can only narrow operator ceilings and cannot enable summaries" do
        let base = defaultHarnessPolicy & #outputRepairs .~ 2 & #output .~ JsonFields ["accepted"] & #deniedTools .~ ["delete"]
            overrides = emptyHarnessOverrides & #maxModelTurns .~ Just 200 & #outputRepairs .~ Just 9 & #permissionSeconds .~ Just 1 & #output .~ Just AnyReply & #deniedTools .~ ["write"] & #summaryTokens .~ Just 50
        narrowed <- expectRight (narrowHarnessPolicy base (Just overrides))
        narrowed.maxModelTurns @?= 8
        narrowed.outputRepairs @?= 2
        narrowed.permissionSeconds @?= 1
        narrowed.deniedTools @?= ["delete", "write"]
        narrowed.output @?= JsonFields ["accepted"]
        narrowed.summaryTokens @?= Nothing
        assertBool "huge natural refused before Int conversion" (isLeft (applyHarnessOptions base (emptyHarnessOverrides & #maxModelTurns .~ Just (10 ^ 100)))),
      testCase "output requirements compose and validate accepted content" do
        policy <- expectRight (narrowHarnessPolicy (defaultHarnessPolicy & #output .~ JsonFields ["one"]) (Just (emptyHarnessOverrides & #output .~ Just (JsonFields ["two"]))))
        assertBool "missing field refused" (isLeft (validateTerminalOutput policy (answer "{\"one\":1}")))
        validateTerminalOutput policy (answer "{\"one\":1,\"two\":2}") @?= Right (Aeson.object ["reply" Aeson..= ("{\"one\":1,\"two\":2}" :: Text.Text)]),
      testCase "tool policy uses immutable bindings and explicit human admission" do
        let assistant = toolReply [("first", "observe", Aeson.object []), ("second", "observe", Aeson.object [])]
            held = defaultHarnessPolicy & #humanTools .~ ["observe"]
        validateToolInvocation held [binding] [binding] assistant 1 @?= Right (ToolNeedsPermission binding)
        assertBool "denial wins over human approval" (isLeft (validateToolInvocation (held & #deniedTools .~ ["observe"]) [binding] [binding] assistant 0))
        assertBool "new revision refused" (isLeft (validateToolInvocation held [binding] [binding & #revision .~ "2"] assistant 0))
        assertBool "scope cannot be invented" (isLeft (validateToolInvocation held [] [binding] assistant 0)),
      testCase "cut-off JSON and duplicate ids never dispatch" do
        mapM_
          (\assistant -> assertBool "invalid tool refused" (isLeft (validateToolInvocation defaultHarnessPolicy [binding] [binding] assistant 0)))
          [toolReply [("id", "observe", Aeson.String "{cut-off")], toolReply [("id", "observe", Aeson.object []), ("id", "observe", Aeson.object [])]]
        assertBool "negative position refused" (isLeft (validateToolInvocation defaultHarnessPolicy [binding] [binding] (toolReply [("id", "observe", Aeson.object [])]) (-1))),
      testCase "compaction preserves anchors and complete tool groups with provenance" do
        let pair = [AssistantTurn (toolReply [("id", "observe", Aeson.object [])]), ToolTurn "id" "observe" [TextBlock (Text.replicate 500 "x")] False Nothing]
            source = ReplayContext 1 (Just "instructions") ([UserTurn [TextBlock "initial request"] Nothing] <> pair <> [UserTurn [TextBlock (Text.replicate 1500 "y")] Nothing, AssistantTurn (answer "latest")])
            policy = defaultHarnessPolicy & #contextBytes .~ 1024 & #keepRecentMessages .~ 1
        view <- expectRight (selectContextView policy source)
        view.kept @?= [0, 4]
        view.omitted @?= [1, 2, 3]
        view.context.systemPrompt @?= Just "instructions"
        length source.messages @?= 5
        Aeson.eitherDecode (Aeson.encode view) @?= Right view,
      testCase "pending calls and signed continuations cannot be compacted away" do
        let opaque = ThinkingBlock "signed" (Just "sig") True (Just (ProviderReplay OpenAIResponses "model" [Aeson.String "opaque"]))
            assistant = (toolReply [("id", "observe", Aeson.object [])]) & #blocks %~ (opaque :)
            source = ReplayContext 1 Nothing [UserTurn [TextBlock "request"] Nothing, AssistantTurn assistant]
            policy = defaultHarnessPolicy & #contextBytes .~ 1024 & #keepRecentMessages .~ 1
        view <- expectRight (selectContextView policy source)
        view.kept @?= [0, 1]
        view.context @?= source
        let oversized = ReplayContext 1 Nothing [UserTurn [TextBlock (Text.replicate 2000 "x")] Nothing, AssistantTurn assistant]
        assertBool "mandatory content cannot be silently truncated" (isLeft (selectContextView policy oversized)),
      testCase "orphan, mismatched and unfinished nonterminal groups refuse replay" do
        let result = ToolTurn "wrong" "observe" [TextBlock "data"] False Nothing
            assistant = AssistantTurn (toolReply [("id", "observe", Aeson.object [])])
        mapM_
          (\messages -> assertBool "corrupt history refused" (isLeft (selectContextView defaultHarnessPolicy (ReplayContext 1 Nothing messages))))
          [[result], [assistant, result], [assistant, UserTurn [TextBlock "next"] Nothing]]
    ]

binding :: ToolBinding
binding = ToolBinding "observe" "1" "schema-digest" RepeatableObservation UnreportedInvoiceCost

answer :: Text.Text -> ReplayAssistant
answer text = ReplayAssistant 1 [TextBlock text] Stop Nothing Nothing (Aeson.object []) Nothing

toolReply :: [(Text.Text, Text.Text, Aeson.Value)] -> ReplayAssistant
toolReply calls = ReplayAssistant 1 [ToolBlock (ToolInvocation callId name args) | (callId, name, args) <- calls] ToolUse Nothing Nothing (Aeson.object []) Nothing

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> fail "expected Right") pure
