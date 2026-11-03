module Shikigami.DecisionRunnerSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Context qualified as Context
import Baikai.Error qualified as Error
import Baikai.Evidence qualified as Evidence
import Baikai.Model qualified as Model
import Baikai.Models.Generated (anthropic_claude_haiku_4_5, anthropic_claude_sonnet_4_6)
import Baikai.Options qualified as Options
import Baikai.Provider.Claude.Api (claudeMessagesProvider)
import Baikai.Provider.Registry (ApiProvider (..), apiProviderWith, newProviderRegistryFrom)
import Baikai.Response (Response (..), emptyResponse, errorResponse)
import Baikai.ResponseFormat (StructuredOutputSupport (NativeJsonSchema))
import Baikai.Stream (liftCompleteToStream)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingHigh))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON, Value (Null, String), toJSON, (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Handan.Runtime (Runtime (..))
import Keiro.Workflow.Types (WorkflowId (..))
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Settei.Env (envSnapshot, environmentSource)
import Settei.Key (parseKey)
import Settei.Optparse (DiagnosticMode (NoDiagnostic), cliOverride)
import Shikigami.App.Config (AppConfig (..), Role (RunBehaviorRole), environmentBindings)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.CallFacts (CallComplianceFacts (..), factsFromTerminal)
import Shikigami.Attestation.Compliance qualified as Compliance
import Shikigami.Attestation.Evidence (CallRelationship (RootCall))
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileFor, resolvedProfileView)
import Shikigami.Behavior.Error (TransientBehaviorFailure)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Decision.ModelCatalog
import Shikigami.Log.Correlation (callCorrelationId, runCorrelationId)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Examples qualified as Examples
import Shikigami.Program.DecisionRunner
import Shikumi.Adapter (ToPrompt)
import Shikumi.LLM (defaultLLMConfig)
import Shikumi.LLM qualified as LLM
import Shikumi.Program (Params (..), Program (..), emptyParams)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema qualified as Schema
import Shikumi.Signature (mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data Answer = Answer {answer :: !Text, confidence :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

predict :: Program Answer Answer
predict = Predict (mkSignature "Return the input with confidence") emptyParams

twoNodes :: RegisteredProgram Answer Answer
twoNodes = register "1" (Compose predict predict) Right

register :: Text -> Program Answer Answer -> (Answer -> Either Text Answer) -> RegisteredProgram Answer Answer
register version program validator = mustRight (registerProgram "runner-fixture" version "sha256:runner" "input/1" "result/1" "validator/1" "derive/1" Null program jsonResultCodec Right validator)

bindingA, bindingB :: ModelBinding
bindingA = binding "triage" anthropic_claude_haiku_4_5 "credential-a"
bindingB = binding "investigate" anthropic_claude_sonnet_4_6 "credential-b"

binding alias model secret = mustRight (modelBinding (fixtureModelAlias alias) "1" alias "1" model Options.emptyOptions (Just (opaqueCredential secret)))

input :: Answer
input = Answer "investigate" 0.81

decisionFrames :: LBS.ByteString
decisionFrames =
  "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5\",\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\n"
    <> "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    <> "data: "
    <> Aeson.encode (Aeson.object ["type" .= ("content_block_delta" :: Text), "index" .= (0 :: Int), "delta" .= Aeson.object ["type" .= ("text_delta" :: Text), "text" .= TE.decodeUtf8 (LBS.toStrict (Aeson.encode input))]])
    <> "\n\n"
    <> "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    <> "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":12}}\n\n"
    <> "data: {\"type\":\"message_stop\"}\n\n"

preparedFor registered binding = PreparedDecision (decisionPreparationId (String "preparation")) (runCorrelationId "run-1") (WorkflowId "workflow-1") initialDecisionGeneration triageDecisionSlot (descriptor (programRef registered)) (toJSON input) (modelDescriptor binding) Nothing

-- Each observed transport request, including its final schema and credential.
data Seen = Seen !Text !(Maybe Text) !Bool
  deriving stock (Eq, Show)

fixture :: Int -> (Int -> Model.Model -> Options.Options -> IO Response) -> IO (ApiProvider, IO [Seen])
fixture delay respond = do
  seen <- newIORef []
  count <- newIORef 0
  let complete model _context options = do
        n <- atomicModifyIORef' count (\n -> (n + 1, n + 1))
        let key = case options.apiKey of Just (ApiKeyLiteral value) -> Just value; _ -> Nothing
        atomicModifyIORef' seen (\xs -> (xs <> [Seen (Model.modelId model) key (options.responseFormat /= Nothing)], ()))
        threadDelay delay
        respond n model options
      handler =
        (apiProviderWith AnthropicMessages (liftCompleteToStream complete) complete)
          { strengthCeiling = Evidence.EvidenceRequestedOnly,
            structuredOutput = NativeJsonSchema
          }
  pure (handler, readIORef seen)

success :: Model.Model -> Options.Options -> Answer -> IO Response
success model options output = do
  now <- getCurrentTime
  callId <- Evidence.newCallId
  let evidence =
        Evidence.baseEvidence
          (maybe (error "missing evidence request") id options.evidence)
          callId
          (Evidence.EndpointIdentity "anthropic" "messages" Evidence.TransportHttpApi (Just (Model.baseUrl model)) "0.7.2.0" (Just "fixture/1"))
          (Model.modelId model)
          Evidence.noThinkingRequested
          now
          now
          Evidence.CallSucceeded
          "sha256:request"
          "sha256:configuration"
  pure
    ( emptyResponse
        & #message
        . #content
        .~ V.singleton (AssistantText (TextContent (TE.decodeUtf8 (LBS.toStrict (Aeson.encode output)))))
        & #evidence
        .~ Just evidence
    )

environment :: RegisteredProgram Answer Answer -> ApiProvider -> DecisionCallHooks -> IO DecisionRuntime
environment registered handler hooks = do
  empty <- newProviderRegistryFrom []
  let config = defaultLLMConfig empty
  pure
    DecisionRuntime
      { runtime = Runtime (config {LLM.retryPolicy = config.retryPolicy {LLM.baseDelayMs = 0, LLM.maxDelayMs = 0}}) anthropic_claude_haiku_4_5,
        programs = mustRight (programRegistry [SomeProgram registered]),
        catalog = mustRight (modelCatalog [bindingA, bindingB]),
        profile = Nothing,
        hooks,
        providers = [handler],
        timeoutMicros = mustRight (parseDecisionTimeout 2_000_000),
        callLimit = (either (error . show) id (PV.mkCeiling 10))
      }

tests :: TestTree
tests =
  testGroup
    "governed decision runner"
    [ testCase "confidence keeps numeric JSON/schema and refuses invalid model leaves" do
        let accepted = mustRight (Examples.parseModelConfidence 0.25)
        Aeson.encode accepted @?= "0.25"
        Aeson.eitherDecode (Aeson.encode accepted) @?= Right accepted
        Schema.toSchema (Proxy @Examples.ModelConfidence) @?= Schema.toSchema (Proxy @Double)
        for_ [-1, 2, 0 / 0, 1 / 0] \bad ->
          assertBool "invalid confidence admission" (isLeft (Examples.parseModelConfidence bad))
        for_ ["-1", "2", "1e10000"] \raw ->
          assertBool "invalid retained confidence" (isLeft (Aeson.eitherDecode @Examples.ModelConfidence raw))
        for_ [-1, 2 :: Double] \bad ->
          assertBool "model decoder keeps admission" (isLeft (Schema.fromModel @Examples.ModelConfidence (Aeson.toJSON bad))),
      testCase "decision timeout checks positivity and native narrowing" do
        decisionTimeoutMicros (mustRight (parseDecisionTimeout 1)) @?= 1
        for_ [0, -1, toInteger (maxBound :: Int) + 1] \bad ->
          assertBool "invalid native timeout" (isLeft (parseDecisionTimeout bad)),
      testCase "two real Predict nodes use selected model, schema, credential and individual hooks" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        result <- runDecisionProgram env (preparedFor twoNodes bindingB) (programRef twoNodes) input
        result @?= Right input
        observed >>= (@?= replicate 2 (Seen (Model.modelId (bindingModel bindingB)) (Just "credential-b") True))
        calls <- inspect
        Map.size calls @?= 2
        assertBool "every terminal persisted" (all (\call -> call.terminal /= Nothing) (Map.elems calls)),
      testCase "concurrent invocations never share model or credential selection" do
        (hooks, _) <- newMemoryCallHooks
        (handler, observed) <- fixture 1000 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        (a, b) <-
          concurrently
            (runDecisionProgram env (preparedFor twoNodes bindingA) (programRef twoNodes) input)
            (runDecisionProgram env (preparedFor twoNodes bindingB) (programRef twoNodes) input)
        (a, b) @?= (Right input, Right input)
        requests <- observed
        length (filter (== Seen (Model.modelId (bindingModel bindingA)) (Just "credential-a") True) requests) @?= 2
        length (filter (== Seen (Model.modelId (bindingModel bindingB)) (Just "credential-b") True) requests) @?= 2,
      testCase "configured decision endpoint and retention reach the public HTTP adapter" do
        for_ [Nothing, Just "none", Just "short", Just "long"] \retention -> do
          seen <- newIORef []
          let application request respond = do
                body <- Wai.strictRequestBody request
                atomicModifyIORef' seen (\xs -> (xs <> [(Wai.pathInfo request, mustRight (Aeson.eitherDecode @Aeson.Value body))], ()))
                respond (Wai.responseLBS status200 [("Content-Type", "text/event-stream")] decisionFrames)
          testWithApplication (pure application) \port -> do
            let endpoint = "http://127.0.0.1:" <> Text.pack (show port) <> "/v1"
                fields =
                  [ "alias" .= ("triage" :: Text),
                    "version" .= ("2" :: Text),
                    "bindingId" .= ("fixture" :: Text),
                    "bindingVersion" .= ("1" :: Text),
                    "provider" .= ("anthropic" :: Text),
                    "model" .= ("claude-haiku-4-5" :: Text),
                    "thinking" .= ("default" :: Text),
                    "base_url" .= endpoint
                  ]
                    <> maybe [] (\value -> ["cache_retention" .= (value :: Text)]) retention
                values = [("behavior.decisionModels", TE.decodeUtf8 . LBS.toStrict . Aeson.encode $ [Aeson.object fields]), ("credentials.providers.anthropic.api_key", "public-fixture-key")]
                configured = appConfigRun RunBehaviorRole ConfigOptions {configPaths = [], namedSources = [], overrides = [cliOverride (mustRight (parseKey key)) value | (key, value) <- values], diagnosticMode = NoDiagnostic} (Right []) (environmentSource environmentBindings (envSnapshot []))
            configured.exitCode @?= 0
            config <- maybe (assertFailure (Text.unpack configured.standardError)) pure configured.resolved
            let catalog = mustRight config.decisionModelCatalog
                selected = mustRight (pinnedBinding catalog (head (catalogDescriptors catalog)))
            (hooks, inspect) <- newMemoryCallHooks
            env <- environment twoNodes claudeMessagesProvider hooks
            let httpsOnly = resolvedProfileFor ((resolvedProfileView forbiddenProfile).profile & #allowedCalls .~ (Profile.AllowedCall (Coordinate.providerCoordinate "anthropic") (Coordinate.providerCoordinate "messages") (Coordinate.providerCoordinate "https") (Coordinate.providerCoordinate "claude-haiku-4-5") Profile.ThinkingHigh :| []))
                guarded = (preparedFor twoNodes selected) {policy = Just (resolvedProfileView httpsOnly).ref} :: PreparedDecision
            runDecisionProgram (env & #catalog .~ catalog & #profile .~ Just httpsOnly) guarded (programRef twoNodes) input >>= (assertBool "plaintext override cannot inherit HTTPS authority" . isLeft)
            readIORef seen >>= (@?= [])
            inspect >>= (\calls -> Map.size calls @?= 0)
            runDecisionProgram (env & #catalog .~ catalog) (preparedFor twoNodes selected) (programRef twoNodes) input >>= (@?= Right input)
            requests <- readIORef seen
            length requests @?= 2
            for_ requests \(path, body) -> do
              path @?= ["v1", "messages"]
              let field name = AesonTypes.parseMaybe (Aeson.withObject "request" (.:? name)) body :: Maybe (Maybe Aeson.Value)
              field "model" @?= Just (Just (String "claude-haiku-4-5"))
              field "cache_control"
                @?= Just
                  ( case retention of
                      Just "short" -> Just (Aeson.object ["type" .= ("ephemeral" :: Text)])
                      Just "long" -> Just (Aeson.object ["type" .= ("ephemeral" :: Text), "ttl" .= ("1h" :: Text)])
                      _ -> Nothing
                  )
            inspect
              >>= ( \calls -> do
                      Map.size calls @?= 2
                      assertBool "each actual HTTP terminal persisted" (all (\call -> call.terminal /= Nothing) (Map.elems calls))
                  ),
      testCase "canonical and historical API evidence compare without rewriting raw facts" do
        for_ [("anthropic-messages", True), ("messages", True), ("openai-chat-completions", False), ("anthropic-messages-cli", False)] \(rawApi, admitted) -> do
          let policy = (resolvedProfileView forbiddenProfile).profile & #allowedCalls .~ (Profile.AllowedCall (Coordinate.providerCoordinate "anthropic") (Coordinate.providerCoordinate "messages") (Coordinate.providerCoordinate "https") (Coordinate.providerCoordinate "claude-haiku-4-5") Profile.ThinkingHigh :| [])
              respond model options = do
                response <- success model options input
                pure (response & #evidence .~ fmap (\terminal -> terminal & #endpoint . #api .~ rawApi) response.evidence)
          (hooks, _) <- newMemoryCallHooks
          (handler, _) <- fixture 0 (\_ -> respond)
          env <- environment twoNodes handler hooks
          result <- runDecisionProgram env (preparedFor twoNodes bindingA) (programRef twoNodes) input
          if admitted then result @?= Right input else assertBool "different API cannot fulfill the selected contract" (isLeft result)
          response <- respond (bindingModel bindingA) (Options.emptyOptions & #evidence .~ Just (Evidence.evidenceRequest "api-fixture"))
          terminal <- maybe (assertFailure "missing fixture evidence") pure response.evidence
          let facts = factsFromTerminal (callCorrelationId (runCorrelationId "api-fixture") "call" 0) RootCall (modelDescriptor bindingA).modelId Nothing terminal
          facts.endpoint.api @?= rawApi
          (Compliance.evaluateCallFacts policy [] [facts]).sanctioned @?= if admitted then Compliance.ComplianceSanctioned else Compliance.ComplianceNonConforming,
      testCase "transient retry crosses hooks again before the second node" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <-
          fixture
            0
            ( \n model options ->
                if n == 1
                  then do
                    now <- getCurrentTime
                    pure (errorResponse model now 0 (Error.httpError 503 Nothing "retry fixture"))
                  else success model options input
            )
        env <- environment twoNodes handler hooks
        runDecisionProgram env (preparedFor twoNodes bindingB) (programRef twoNodes) input >>= (@?= Right input)
        observed >>= (\requests -> length requests @?= 3)
        inspect >>= (\calls -> Map.size calls @?= 3),
      testCase "a maximum Int retry ceiling preserves the native retry budget" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <-
          fixture
            0
            ( \n model options ->
                if n == 1
                  then do
                    now <- getCurrentTime
                    pure (errorResponse model now 0 (Error.httpError 503 Nothing "retry edge"))
                  else success model options input
            )
        env <- environment twoNodes handler hooks
        let content =
              (resolvedProfileView forbiddenProfile).profile
                & #allowedCalls
                .~ (Profile.AllowedCall (Coordinate.providerCoordinate "anthropic") (Coordinate.providerCoordinate "messages") (Coordinate.providerCoordinate "https") (Coordinate.providerCoordinate (Model.modelId (bindingModel bindingB))) Profile.ThinkingHigh :| [])
                & #limits
                .~ (Profile.unlimitedProfileLimits & #maxRetries .~ Just (mustRight (PV.mkCeiling (maxBound :: Int))))
            policy = resolvedProfileFor content
            prepared = (preparedFor twoNodes bindingB) {policy = Just (resolvedProfileView policy).ref} :: PreparedDecision
        runDecisionProgram (env & #profile .~ Just policy) prepared (programRef twoNodes) input >>= (@?= Right input)
        observed >>= (\requests -> length requests @?= 3)
        inspect >>= (\calls -> Map.size calls @?= 3),
      testCase "pinned state and input mismatches dispatch nothing" do
        (hooks, _) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        let prepared = preparedFor twoNodes bindingA
            changed :: PreparedDecision
            changed = (prepared & #program .~ ((prepared.program) {parameterDigest = programParameterDigest (Aeson.String "other")}))
        runDecisionProgram env changed (programRef twoNodes) input >>= (assertBool "state refused" . isLeft)
        runDecisionProgram env prepared (programRef twoNodes) (Answer "changed" 0.1) >>= (assertBool "input refused" . isLeft)
        observed >>= (@?= []),
      testCase "the pinned profile is checked on the final dispatch tuple" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        let policy = forbiddenProfile
            prepared = (preparedFor twoNodes bindingA) {policy = Just (resolvedProfileView policy).ref} :: PreparedDecision
        result <- runDecisionProgram ((env & #profile .~ (Just policy))) prepared (programRef twoNodes) input
        assertBool "profile refuses actual selected model" (isLeft result)
        observed >>= (@?= [])
        inspect >>= (\calls -> Map.size calls @?= 0),
      testCase "call cap spans both nodes" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        result <- runDecisionProgram ((env & #callLimit .~ (either (error . show) id (PV.mkCeiling 1)))) (preparedFor twoNodes bindingA) (programRef twoNodes) input
        either (Right . failureCode) (const (Left ())) result @?= Right CallLimitExceeded
        observed >>= (\requests -> length requests @?= 1)
        inspect >>= (\calls -> Map.size calls @?= 1),
      testCase "evidence callback failure cannot become an internal retry" do
        (hooks, _) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        let broken = (hooks & #finishCall .~ (\_ _ _ -> ioError (userError "private callback error")))
        env <- environment twoNodes handler broken
        result <- runDecisionProgram env (preparedFor twoNodes bindingA) (programRef twoNodes) input
        assertBool "failed" (isLeft result)
        observed >>= (\requests -> length requests @?= 1),
      testCase "invalid JSON and missing evidence never return a decision" do
        (hooks, _) <- newMemoryCallHooks
        (badJSON, _) <-
          fixture
            0
            ( \_ model options -> do
                response <- success model options input
                pure (response & #message . #content .~ V.singleton (AssistantText (TextContent "private invalid body")))
            )
        env <- environment twoNodes badJSON hooks
        malformed <- runDecisionProgram env (preparedFor twoNodes bindingA) (programRef twoNodes) input
        assertBool "malformed output refused" (isLeft malformed)
        (missingEvidence, _) <-
          fixture
            0
            ( \_ model options -> do
                response <- success model options input
                pure (response & #evidence .~ Nothing)
            )
        absent <- runDecisionProgram ((env & #providers .~ ([missingEvidence]))) (preparedFor twoNodes bindingA) (programRef twoNodes) input
        assertBool "missing terminal refused" (isLeft absent),
      testCase "an explicit forbidden thinking override dispatches nothing" do
        let overridden =
              register
                "thinking"
                ( Embed
                    ( \value -> do
                        _ <- LLM.complete Model.emptyModel Context.emptyContext ((Options.emptyOptions & #thinking .~ (Just ThinkingHigh)))
                        pure value
                    )
                )
                Right
        (hooks, _) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment overridden handler hooks
        result <- runDecisionProgram env (preparedFor overridden bindingA) (programRef overridden) input
        assertBool "thinking refused" (isLeft result)
        observed >>= (@?= []),
      testCase "pinned cache retention survives complete and stream merging; conflicts never dispatch" do
        for_ [False, True] \streaming ->
          for_ [Nothing, Just CacheRetentionNone, Just CacheRetentionShort, Just CacheRetentionLong] \pinned ->
            for_ [Nothing, Just CacheRetentionShort, Just CacheRetentionNone, Just CacheRetentionLong] \requested -> do
              let registered =
                    register
                      "cache"
                      ( Embed
                          ( \value -> do
                              let options = Options.emptyOptions & #cacheRetention .~ requested
                              if streaming then void (LLM.stream Model.emptyModel Context.emptyContext options) else void (LLM.complete Model.emptyModel Context.emptyContext options)
                              pure value
                          )
                      )
                      Right
                  selected = mustRight (modelBinding (fixtureModelAlias "triage") "2" "cached" "1" anthropic_claude_haiku_4_5 (Options.emptyOptions & #cacheRetention .~ pinned) (Just (opaqueCredential "credential-a")))
              (hooks, inspect) <- newMemoryCallHooks
              retained <- newIORef []
              (handler, observed) <-
                fixture
                  0
                  ( \_ model options -> do
                      atomicModifyIORef' retained (\xs -> (xs <> [options.cacheRetention], ()))
                      success model options input
                  )
              env <- environment registered handler hooks
              result <- runDecisionProgram (env & #catalog .~ mustRight (modelCatalog [selected])) (preparedFor registered selected) (programRef registered) input
              if pinned == Nothing || requested == Nothing || requested == pinned
                then do
                  result @?= Right input
                  readIORef retained >>= (@?= [case pinned of Nothing -> requested; Just value -> Just value])
                  inspect >>= (\calls -> Map.size calls @?= 1)
                else do
                  assertBool "cache override refused" (isLeft result)
                  observed >>= (@?= [])
                  inspect >>= (\calls -> Map.size calls @?= 0),
      testCase "domain-invalid output remains failure with bounded diagnostics" do
        let registered = register "reject" predict (const (Left "private model body"))
        (hooks, _) <- newMemoryCallHooks
        (handler, _) <- fixture 0 (\_ model options -> success model options input)
        env <- environment registered handler hooks
        result <- runDecisionProgram env (preparedFor registered bindingA) (programRef registered) input
        case result of
          Left failure -> failureCode failure @?= OutputValidationFailure
          Right _ -> assertFailure "expected domain refusal",
      testCase "streaming dispatch counts one transport attempt and persists its terminal" do
        let streamed =
              register
                "stream"
                ( Embed
                    ( \value -> do
                        _ <- LLM.stream Model.emptyModel Context.emptyContext Options.emptyOptions
                        pure value
                    )
                )
                Right
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment streamed handler hooks
        runDecisionProgram env (preparedFor streamed bindingA) (programRef streamed) input >>= (@?= Right input)
        observed >>= (\requests -> length requests @?= 1)
        calls <- inspect
        Map.size calls @?= 1
        assertBool "terminal persisted" (all (\call -> call.terminal /= Nothing) (Map.elems calls)),
      testCase "admission callback refusal sends no request" do
        (hooks, _) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        let denied = (hooks & #beginCall .~ (\_ -> pure (Left (decisionFailure EvidenceFailure "persistence unavailable"))))
        env <- environment twoNodes handler denied
        runDecisionProgram env (preparedFor twoNodes bindingA) (programRef twoNodes) input >>= (assertBool "refused" . isLeft)
        observed >>= (@?= []),
      testCase "timeout leaves an unresolved expectation" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, _) <- fixture 100_000 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        result <- try @TransientBehaviorFailure (runDecisionProgram ((env & #timeoutMicros .~ (either (error . show) id (parseDecisionTimeout 20_000)))) (preparedFor twoNodes bindingA) (programRef twoNodes) input)
        assertBool "timeout remains retryable" (isLeft result)
        calls <- inspect
        Map.size calls @?= 1
        assertBool "not a fabricated terminal" (all (\call -> call.terminal == Nothing) (Map.elems calls))
    ]

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

concurrently :: IO a -> IO b -> IO (a, b)
concurrently left right = do
  a <- newEmptyMVar
  b <- newEmptyMVar
  _ <- forkIO (try @SomeException left >>= putMVar a)
  _ <- forkIO (try @SomeException right >>= putMVar b)
  x <- takeMVar a >>= either throwIO pure
  y <- takeMVar b >>= either throwIO pure
  pure (x, y)

forbiddenProfile :: ResolvedProfile
forbiddenProfile = resolvedProfileFor content
  where
    content =
      Profile.SanctionedExecutionProfile
        { profileId = Profile.ProfileId "runner",
          version = Profile.ProfileVersion "1",
          issuer = Profile.Issuer "test",
          lifecycle = Profile.Active,
          validFrom = UTCTime (fromGregorian 2026 1 1) 0,
          validUntil = Nothing,
          allowedCalls = Profile.AllowedCall (Coordinate.providerCoordinate "anthropic") (Coordinate.providerCoordinate "messages") (Coordinate.providerCoordinate "https") (Coordinate.providerCoordinate "forbidden-selected-model") Profile.ThinkingHigh :| [],
          prohibitions = (Profile.defaultProhibitions & #defaultedThinkingAllowed .~ (PV.Permitted)),
          limits = Profile.unlimitedProfileLimits,
          minimumEvidenceStrength = Profile.EvidenceRequestedOnly,
          requiredCorrelationFields = [],
          signerRequirements = Profile.noSignerRequirements
        }

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
