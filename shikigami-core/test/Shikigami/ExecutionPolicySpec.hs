module Shikigami.ExecutionPolicySpec (tests) where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Control.Lens ((%~), (&), (.~))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Shikigami.Behavior.Provider.Coordinate qualified as ProviderValue
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Payload (parsePayloadByteCount, parsePayloadDigest, parsePayloadId)
import Shikigami.Execution.Policy
import Shikigami.Execution.Policy.Limits (PolicyNumber (..))
import Shikigami.Execution.ToolPosition (ToolPosition, parseToolPosition)
import Shikigami.Execution.Transcript
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Workspace.Instructions (instructionPrompt, mkInstructionBundle)
import Shikigami.Workspace.Value
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionPolicy"
    [ testCase "technical execution workflow identity has a stable separator-safe vector" do
        let workflow = executionWorkflowId (executionIdentity "execution:fixture")
        workflow.unWorkflowId @?= "89a70fa2-523e-5bf7-908c-2bdeb675badb"
        mkWorkflowId workflow.unWorkflowId @?= Right workflow,
      testCase "historical tool bindings retain unknown invoice cost and identical JSON" do
        let legacy = "{\"name\":\"observe\",\"revision\":\"1\",\"schemaDigest\":\"schema-digest\",\"recovery\":\"RepeatableObservation\"}"
        Aeson.eitherDecode @ToolBinding legacy @?= Right binding
        Aeson.eitherDecode @Aeson.Value legacy @?= Right (Aeson.toJSON binding)
        assertBool "a zero-invoice declaration changes immutable scope" (toolScopeDigest binding /= toolScopeDigest (binding & #invoiceCost .~ NoInvoiceCost)),
      testCase "checked policy fields keep exact numeric bytes and reject each invalid bound" do
        let policy = defaultHarnessPolicy & #summaryTokens .~ Just (fixturePolicy 64)
            expected =
              Aeson.object
                [ "format" .= (1 :: Int),
                  "maxModelTurns" .= (8 :: Int),
                  "outputRepairs" .= (0 :: Int),
                  "contextBytes" .= (262144 :: Int),
                  "keepRecentMessages" .= (4 :: Int),
                  "deniedTools" .= ([] :: [Text]),
                  "humanTools" .= ([] :: [Text]),
                  "permissionSeconds" .= (900 :: Int),
                  "output" .= AnyReply,
                  "recoveryAttempts" .= (2 :: Int),
                  "summaryTokens" .= (64 :: Int)
                ]
        Aeson.eitherDecode (Aeson.encode policy) @?= Right policy
        Aeson.encode policy @?= Aeson.encode expected
        case Aeson.toJSON policy of
          Aeson.Object fields ->
            mapM_
              ( \(key, number) ->
                  assertBool
                    "invalid policy bound refused"
                    (case Aeson.fromJSON (Aeson.Object (KeyMap.insert key (Aeson.toJSON (number :: Integer)) fields)) :: Aeson.Result HarnessPolicy of Aeson.Error _ -> True; Aeson.Success _ -> False)
              )
              [(key, bad) | (key, lower, upper) <- [("maxModelTurns", 1, 10000), ("outputRepairs", 0, 10), ("contextBytes", 1024, 1048576), ("keepRecentMessages", 1, 1000), ("permissionSeconds", 1, 86400), ("recoveryAttempts", 0, 100), ("summaryTokens", 1, 32768)], bad <- [lower - 1, upper + 1]]
          _ -> assertFailure "policy did not encode as an object",
      testCase "old policy bytes and empty snapshots keep their digest inputs" do
        let policy = defaultHarnessPolicy
        Aeson.eitherDecode (Aeson.encode policy) @?= Right policy
        case Aeson.toJSON policy of
          Aeson.Object fields -> assertBool "absent extension omitted" (not (KeyMap.member "summaryTokens" fields))
          _ -> assertFailure "expected object"
        Aeson.eitherDecode @HarnessOverrides "{}" @?= Right emptyHarnessOverrides
        assertBool "unknown policy options refused" (isLeft (Aeson.eitherDecode @HarnessOverrides "{\"grantTool\":true}")),
      testCase "historical policy bytes do not gain recovery authority" do
        let legacy = defaultHarnessPolicy & #recoveryAttempts .~ (fixturePolicy 0)
        case Aeson.toJSON legacy of
          Aeson.Object fields -> assertBool "absent recovery authority omitted" (not (KeyMap.member "recoveryAttempts" fields))
          _ -> assertFailure "expected policy object"
        Aeson.eitherDecode (Aeson.encode legacy) @?= Right legacy
        narrowed <- expectRight (narrowHarnessPolicy defaultHarnessPolicy (Just (emptyHarnessOverrides & #recoveryAttempts .~ Just 100)))
        narrowed.recoveryAttempts @?= (fixturePolicy 2)
        assertBool "unbounded recovery refused" (isLeft (applyHarnessOptions defaultHarnessPolicy (emptyHarnessOverrides & #recoveryAttempts .~ Just 101))),
      testCase "historical model input bytes omit the new provenance extension" do
        context <- expectRight (selectContextView defaultHarnessPolicy (ReplayContext LegacyContext Nothing [UserTurn [TextBlock "request"] Nothing]))
        let legacy = Aeson.object ["format" .= (1 :: Int), "view" .= context, "maxOutputTokens" .= (Nothing :: Maybe Int)]
            input = ModelOperationInput V1 context Nothing Nothing
        Aeson.fromJSON legacy @?= Aeson.Success input
        Aeson.toJSON input @?= legacy,
      testCase "an enabled summary refuses a source it cannot faithfully include" do
        let policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 1024) & #keepRecentMessages .~ (fixturePolicy 1) & #summaryTokens .~ Just (fixturePolicy 64)
            source = ReplayContext LegacyContext Nothing [UserTurn [TextBlock "request"] Nothing, UserTurn [TextBlock (Text.replicate 3000 "x")] Nothing, AssistantTurn (answer "latest")]
        prepareModelOperationInput policy ModelTurn source Nothing Nothing @?= Left (ExecutionPolicyRefused "summary source exceeds the context ceiling"),
      testCase "version-2 summary requests and accepted summaries retain the actual request" do
        bundle <- expectRight (mkInstructionBundle 65536 (repositoryId ("mori://fixture/repo")) ((workspaceCoordinate (Text.replicate 40 "a"))) [((workspaceCoordinate ("AGENTS.md")), "frozen repository requirements")])
        let policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 3600) & #keepRecentMessages .~ (fixturePolicy 1) & #summaryTokens .~ Just (fixturePolicy 64)
            request = RequestTurn [TextBlock "current request"] Nothing
            source = ReplayContext RequestContext (Just (instructionPrompt bundle)) [UserTurn [TextBlock (Text.replicate 1000 "x")] Nothing, AssistantTurn (answer (Text.replicate 1000 "y")), request, AssistantTurn (answer (Text.replicate 1000 "z"))]
            execution = executionIdentity "summary-fixture"
            specification = OperationSpec (operationIdFor execution (fixtureRevision 0)) ModelSummary RepeatableObservation (ExecutionValue.executionCoordinate "summary") (ExecutionValue.executionDigest "policy") (ExecutionValue.executionDigest "scope") Nothing
            ref = fixturePayloadRef "payload" ("sha256:" <> Text.replicate 64 "a") 1
            operation = Operation V1 execution (fixtureRevision 0) specification (ExecutionValue.executionDigest "fingerprint") ref (Just ref) (Just NeedModel) NotMarkedUncertain Nothing
        (kind, input) <- expectRight (prepareModelOperationInput policy ModelTurn source Nothing Nothing)
        kind @?= ModelSummary
        input.view.context.systemPrompt @?= source.systemPrompt
        input.view.context.format @?= RequestContext
        contextRequest input.view.context.messages @?= Just request
        (next, accepted) <- expectRight (prepareModelOperationInput policy ModelTurn source Nothing (Just (operation, input, answer "retained facts")))
        next @?= ModelTurn
        accepted.view.context.systemPrompt @?= source.systemPrompt
        accepted.view.context.format @?= RequestContext
        contextRequest accepted.view.context.messages @?= Just request
        assertBool "accepted summary is referenced" (maybe False (maybe False (const True) . (.summary)) accepted.provenance),
      testCase "an accepted summary with unsupported provenance is refused rather than resampled" do
        let policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 1024) & #keepRecentMessages .~ (fixturePolicy 1) & #summaryTokens .~ Just (fixturePolicy 64)
            source = ReplayContext LegacyContext Nothing [UserTurn [TextBlock "request"] Nothing, UserTurn [TextBlock (Text.replicate 3000 "x")] Nothing, AssistantTurn (answer "latest")]
            execution = executionIdentity "summary-fixture"
            specification = OperationSpec (operationIdFor execution (fixtureRevision 0)) ModelSummary RepeatableObservation (ExecutionValue.executionCoordinate "summary") (ExecutionValue.executionDigest "policy") (ExecutionValue.executionDigest "scope") Nothing
            ref = fixturePayloadRef "payload" ("sha256:" <> Text.replicate 64 "a") 1
            operation = Operation V1 execution (fixtureRevision 0) specification (ExecutionValue.executionDigest "fingerprint") ref (Just ref) (Just NeedModel) NotMarkedUncertain Nothing
        selected <- expectRight (selectContextView policy source)
        let old = ModelOperationInput V1 selected (Just (fixturePolicy 64)) Nothing
        prepareModelOperationInput policy ModelTurn source Nothing (Just (operation, old, answer "accepted")) @?= Left UnsupportedReplay,
      testCase "declaration can only narrow operator ceilings and cannot enable summaries" do
        let base = defaultHarnessPolicy & #outputRepairs .~ (fixturePolicy 2) & #output .~ JsonFields (map ExecutionValue.executionCoordinate ["accepted"]) & #deniedTools .~ (map ExecutionValue.executionCoordinate ["delete"])
            overrides = emptyHarnessOverrides & #maxModelTurns .~ Just 200 & #outputRepairs .~ Just 9 & #permissionSeconds .~ Just 1 & #output .~ Just AnyReply & #deniedTools .~ (map ExecutionValue.executionCoordinate ["write"]) & #summaryTokens .~ Just 50
        narrowed <- expectRight (narrowHarnessPolicy base (Just overrides))
        narrowed.maxModelTurns @?= (fixturePolicy 8)
        narrowed.outputRepairs @?= (fixturePolicy 2)
        narrowed.permissionSeconds @?= (fixturePolicy 1)
        narrowed.deniedTools @?= (map ExecutionValue.executionCoordinate ["delete", "write"])
        narrowed.output @?= JsonFields (map ExecutionValue.executionCoordinate ["accepted"])
        narrowed.summaryTokens @?= Nothing
        assertBool "huge natural refused before Int conversion" (isLeft (applyHarnessOptions base (emptyHarnessOverrides & #maxModelTurns .~ Just (10 ^ 100)))),
      testCase "output requirements compose and validate accepted content" do
        policy <- expectRight (narrowHarnessPolicy (defaultHarnessPolicy & #output .~ JsonFields (map ExecutionValue.executionCoordinate ["one"])) (Just (emptyHarnessOverrides & #output .~ Just (JsonFields (map ExecutionValue.executionCoordinate ["two"])))))
        assertBool "missing field refused" (isLeft (validateTerminalOutput policy (answer "{\"one\":1}")))
        validateTerminalOutput policy (answer "{\"one\":1,\"two\":2}") @?= Right (Aeson.object ["reply" .= ("{\"one\":1,\"two\":2}" :: Text.Text)]),
      testCase "tool policy uses immutable bindings and explicit human admission" do
        let assistant = toolReply [("first", "observe", Aeson.object []), ("second", "observe", Aeson.object [])]
            held = defaultHarnessPolicy & #humanTools .~ (map ExecutionValue.executionCoordinate ["observe"])
        validateToolInvocation held [binding] [binding] assistant (fixtureToolPosition 1) @?= Right (ToolNeedsPermission binding)
        let response = fixturePayloadRef "response" ("sha256:" <> Text.replicate 64 "a") 1
            first = ToolOperationInput response (fixtureToolPosition 0) (ToolInvocation (ProviderValue.providerCoordinate "first") (ExecutionValue.executionCoordinate "observe") (Aeson.object [])) binding
        toolContinuation first assistant @?= NeedTool response (fixtureToolPosition 1)
        toolContinuation (first & #position .~ fixtureToolPosition 1) assistant @?= NeedModel
        assertBool "denial wins over human approval" (isLeft (validateToolInvocation (held & #deniedTools .~ (map ExecutionValue.executionCoordinate ["observe"])) [binding] [binding] assistant (fixtureToolPosition 0)))
        assertBool "new revision refused" (isLeft (validateToolInvocation held [binding] [binding & #revision .~ ExecutionValue.executionCoordinate "2"] assistant (fixtureToolPosition 0)))
        assertBool "scope cannot be invented" (isLeft (validateToolInvocation held [] [binding] assistant (fixtureToolPosition 0))),
      testCase "cut-off JSON and duplicate ids never dispatch" do
        mapM_
          (\assistant -> assertBool "invalid tool refused" (isLeft (validateToolInvocation defaultHarnessPolicy [binding] [binding] assistant (fixtureToolPosition 0))))
          [toolReply [("id", "observe", Aeson.String "{cut-off")], toolReply [("id", "observe", Aeson.object []), ("id", "observe", Aeson.object [])]]
        assertBool "negative position refused" (isLeft (parseToolPosition (-1))),
      testCase "compaction preserves anchors and complete tool groups with provenance" do
        let pair = [AssistantTurn (toolReply [("id", "observe", Aeson.object [])]), ToolTurn (ProviderValue.providerCoordinate "id") (ExecutionValue.executionCoordinate "observe") [TextBlock (Text.replicate 500 "x")] ExecutionValue.ToolSucceeded Nothing]
            source = ReplayContext LegacyContext (Just "instructions") ([UserTurn [TextBlock "initial request"] Nothing] <> pair <> [UserTurn [TextBlock (Text.replicate 1500 "y")] Nothing, AssistantTurn (answer "latest")])
            policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 1024) & #keepRecentMessages .~ (fixturePolicy 1)
        view <- expectRight (selectContextView policy source)
        map contextPositionNumber view.kept @?= [0, 4]
        map contextPositionNumber view.omitted @?= [1, 2, 3]
        view.context.systemPrompt @?= Just "instructions"
        length source.messages @?= 5
        Aeson.eitherDecode (Aeson.encode view) @?= Right view,
      testCase "version-2 request anchors survive compaction after newer messages" do
        let request = RequestTurn [TextBlock "current request"] Nothing
            source = ReplayContext RequestContext (Just "instructions") [UserTurn [TextBlock (Text.replicate 2000 "old")] Nothing, AssistantTurn (answer "old reply"), request, UserTurn [TextBlock (Text.replicate 2000 "repair")] Nothing, AssistantTurn (answer "latest")]
            policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 1024) & #keepRecentMessages .~ (fixturePolicy 1)
        selected <- expectRight (selectContextView policy source)
        selected.context.format @?= RequestContext
        contextRequest selected.context.messages @?= Just request
        assertBool "old conversation context remains optional" (0 `elem` map contextPositionNumber selected.omitted)
        assertBool "the actual request is mandatory even outside the recent window" (2 `elem` map contextPositionNumber selected.kept)
        Aeson.eitherDecode (Aeson.encode selected.context) @?= Right selected.context,
      testCase "context versions reject missing duplicate and misplaced request markers" do
        let request = RequestTurn [TextBlock "request"] Nothing
        mapM_
          (\context -> assertBool "invalid context header refused" (isLeft (restoreContext context)))
          [ReplayContext LegacyContext Nothing [request], ReplayContext RequestContext Nothing [UserTurn [TextBlock "request"] Nothing], ReplayContext RequestContext Nothing [request, request]]
        let legacy = ReplayContext LegacyContext Nothing [UserTurn [TextBlock "original"] Nothing]
        Aeson.eitherDecode (Aeson.encode legacy) @?= Right legacy
        let unsupported = Aeson.object ["format" .= (3 :: Int), "systemPrompt" .= Aeson.Null, "messages" .= ([UserTurn [TextBlock "original"] Nothing] :: [ReplayMessage])]
        assertBool "unsupported context version refused at decoding" (isLeft (Aeson.eitherDecode @ReplayContext (Aeson.encode unsupported))),
      testCase "pending calls and signed continuations cannot be compacted away" do
        let opaque = ThinkingBlock "signed" (Just "sig") True (Just (ProviderReplay OpenAIResponses (ProviderValue.providerCoordinate "model") [Aeson.String "opaque"]))
            assistant = (toolReply [("id", "observe", Aeson.object [])]) & #blocks %~ (opaque :)
            source = ReplayContext LegacyContext Nothing [UserTurn [TextBlock "request"] Nothing, AssistantTurn assistant]
            policy = defaultHarnessPolicy & #contextBytes .~ (fixturePolicy 1024) & #keepRecentMessages .~ (fixturePolicy 1)
        view <- expectRight (selectContextView policy source)
        map contextPositionNumber view.kept @?= [0, 1]
        view.context @?= source
        let oversized = ReplayContext LegacyContext Nothing [UserTurn [TextBlock (Text.replicate 2000 "x")] Nothing, AssistantTurn assistant]
        assertBool "mandatory content cannot be silently truncated" (isLeft (selectContextView policy oversized)),
      testCase "orphan, mismatched and unfinished nonterminal groups refuse replay" do
        let result = ToolTurn (ProviderValue.providerCoordinate "wrong") (ExecutionValue.executionCoordinate "observe") [TextBlock "data"] ExecutionValue.ToolSucceeded Nothing
            assistant = AssistantTurn (toolReply [("id", "observe", Aeson.object [])])
        mapM_
          (\messages -> assertBool "corrupt history refused" (isLeft (selectContextView defaultHarnessPolicy (ReplayContext LegacyContext Nothing messages))))
          [[result], [assistant, result], [assistant, UserTurn [TextBlock "next"] Nothing]]
    ]

binding :: ToolBinding
binding = ToolBinding (ExecutionValue.executionCoordinate "observe") (ExecutionValue.executionCoordinate "1") (ExecutionValue.executionDigest "schema-digest") RepeatableObservation UnreportedInvoiceCost

answer :: Text.Text -> ReplayAssistant
answer text = ReplayAssistant V1 [TextBlock text] Stop Nothing Nothing (Aeson.object []) Nothing

toolReply :: [(Text.Text, Text.Text, Aeson.Value)] -> ReplayAssistant
toolReply calls = ReplayAssistant V1 [ToolBlock (ToolInvocation (ProviderValue.providerCoordinate callId) (ExecutionValue.executionCoordinate name) args) | (callId, name, args) <- calls] ToolUse Nothing Nothing (Aeson.object []) Nothing

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> fail "expected Right") pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixturePolicy :: (PolicyNumber a) => Integer -> a
fixturePolicy number = either (error . show) id (parsePolicyNumber number)

fixtureToolPosition :: Integer -> ToolPosition
fixtureToolPosition value = either (error . show) id (parseToolPosition value)

fixturePayloadRef :: Text -> Text -> Integer -> PayloadRef
fixturePayloadRef locator digest size =
  PayloadRef
    (either (error . show) id (parsePayloadId locator))
    (either (error . show) id (parsePayloadDigest digest))
    (either (error . show) id (parsePayloadByteCount size))
