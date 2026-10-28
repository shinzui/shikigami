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
      testCase "historical policy bytes do not gain recovery authority" do
        let legacy = defaultHarnessPolicy & #recoveryAttempts .~ 0
        case Aeson.toJSON legacy of
          Aeson.Object fields -> assertBool "absent recovery authority omitted" (not (KeyMap.member "recoveryAttempts" fields))
          _ -> assertFailure "expected policy object"
        Aeson.eitherDecode (Aeson.encode legacy) @?= Right legacy
        narrowed <- expectRight (narrowHarnessPolicy defaultHarnessPolicy (Just (emptyHarnessOverrides & #recoveryAttempts .~ Just 100)))
        narrowed.recoveryAttempts @?= 2
        assertBool "unbounded recovery refused" (isLeft (applyHarnessOptions defaultHarnessPolicy (emptyHarnessOverrides & #recoveryAttempts .~ Just 101))),
      testCase "historical model input bytes omit the new provenance extension" do
        context <- expectRight (selectContextView defaultHarnessPolicy (ReplayContext 1 Nothing [UserTurn [TextBlock "request"] Nothing]))
        let legacy = Aeson.object ["format" Aeson..= (1 :: Int), "view" Aeson..= context, "maxOutputTokens" Aeson..= (Nothing :: Maybe Int)]
            input = ModelOperationInput 1 context Nothing Nothing
        Aeson.fromJSON legacy @?= Aeson.Success input
        Aeson.toJSON input @?= legacy,
      testCase "an enabled summary refuses a source it cannot faithfully include" do
        let policy = defaultHarnessPolicy & #contextBytes .~ 1024 & #keepRecentMessages .~ 1 & #summaryTokens .~ Just 64
            source = ReplayContext 1 Nothing [UserTurn [TextBlock "request"] Nothing, UserTurn [TextBlock (Text.replicate 3000 "x")] Nothing, AssistantTurn (answer "latest")]
        prepareModelOperationInput policy ModelTurn source Nothing Nothing @?= Left (ExecutionPolicyRefused "summary source exceeds the context ceiling"),
      testCase "version-2 summary requests and accepted summaries retain the actual request" do
        let policy = defaultHarnessPolicy & #contextBytes .~ 3000 & #keepRecentMessages .~ 1 & #summaryTokens .~ Just 64
            request = RequestTurn [TextBlock "current request"] Nothing
            source = ReplayContext 2 Nothing [UserTurn [TextBlock (Text.replicate 1000 "x")] Nothing, AssistantTurn (answer (Text.replicate 1000 "y")), request, AssistantTurn (answer (Text.replicate 1000 "z"))]
            execution = ExecutionId "summary-fixture"
            specification = OperationSpec (operationIdFor execution 0) ModelSummary RepeatableObservation "summary" "policy" "scope" Nothing
            ref = PayloadRef "payload" "digest" 1
            operation = Operation 1 execution 0 specification "fingerprint" ref (Just ref) (Just NeedModel) False Nothing
        (kind, input) <- expectRight (prepareModelOperationInput policy ModelTurn source Nothing Nothing)
        kind @?= ModelSummary
        input.view.context.format @?= 2
        contextRequest input.view.context.messages @?= Just request
        (next, accepted) <- expectRight (prepareModelOperationInput policy ModelTurn source Nothing (Just (operation, input, answer "retained facts")))
        next @?= ModelTurn
        accepted.view.context.format @?= 2
        contextRequest accepted.view.context.messages @?= Just request
        assertBool "accepted summary is referenced" (maybe False (maybe False (const True) . (.summary)) accepted.provenance),
      testCase "an accepted summary with unsupported provenance is refused rather than resampled" do
        let policy = defaultHarnessPolicy & #contextBytes .~ 1024 & #keepRecentMessages .~ 1 & #summaryTokens .~ Just 64
            source = ReplayContext 1 Nothing [UserTurn [TextBlock "request"] Nothing, UserTurn [TextBlock (Text.replicate 3000 "x")] Nothing, AssistantTurn (answer "latest")]
            execution = ExecutionId "summary-fixture"
            specification = OperationSpec (operationIdFor execution 0) ModelSummary RepeatableObservation "summary" "policy" "scope" Nothing
            ref = PayloadRef "payload" "digest" 1
            operation = Operation 1 execution 0 specification "fingerprint" ref (Just ref) (Just NeedModel) False Nothing
        selected <- expectRight (selectContextView policy source)
        let old = ModelOperationInput 1 selected (Just 64) Nothing
        prepareModelOperationInput policy ModelTurn source Nothing (Just (operation, old, answer "accepted")) @?= Left UnsupportedReplay,
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
      testCase "version-2 request anchors survive compaction after newer messages" do
        let request = RequestTurn [TextBlock "current request"] Nothing
            source = ReplayContext 2 (Just "instructions") [UserTurn [TextBlock (Text.replicate 2000 "old")] Nothing, AssistantTurn (answer "old reply"), request, UserTurn [TextBlock (Text.replicate 2000 "repair")] Nothing, AssistantTurn (answer "latest")]
            policy = defaultHarnessPolicy & #contextBytes .~ 1024 & #keepRecentMessages .~ 1
        selected <- expectRight (selectContextView policy source)
        selected.context.format @?= 2
        contextRequest selected.context.messages @?= Just request
        assertBool "old conversation context remains optional" (0 `elem` selected.omitted)
        assertBool "the actual request is mandatory even outside the recent window" (2 `elem` selected.kept)
        Aeson.eitherDecode (Aeson.encode selected.context) @?= Right selected.context,
      testCase "context versions reject missing duplicate and misplaced request markers" do
        let request = RequestTurn [TextBlock "request"] Nothing
        mapM_
          (\context -> assertBool "invalid context header refused" (isLeft (restoreContext context)))
          [ReplayContext 1 Nothing [request], ReplayContext 2 Nothing [UserTurn [TextBlock "request"] Nothing], ReplayContext 2 Nothing [request, request], ReplayContext 3 Nothing [request]]
        let legacy = ReplayContext 1 Nothing [UserTurn [TextBlock "original"] Nothing]
        Aeson.eitherDecode (Aeson.encode legacy) @?= Right legacy,
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
