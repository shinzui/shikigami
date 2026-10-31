module Shikigami.DecisionRunnerSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Context qualified as Context
import Baikai.Error qualified as Error
import Baikai.Evidence qualified as Evidence
import Baikai.Model qualified as Model
import Baikai.Models.Generated (anthropic_claude_haiku_4_5, anthropic_claude_sonnet_4_6)
import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider (..), apiProviderWith, newProviderRegistryFrom)
import Baikai.Response (Response (..), emptyResponse, errorResponse)
import Baikai.ResponseFormat (StructuredOutputSupport (NativeJsonSchema))
import Baikai.Stream (liftCompleteToStream)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingHigh))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.Aeson (FromJSON, ToJSON, Value (Null), toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Handan.Runtime (Runtime (..))
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.Error (TransientBehaviorFailure)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Decision.ModelCatalog
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Program.Decision
import Shikigami.Program.DecisionRunner
import Shikumi.Adapter (ToPrompt)
import Shikumi.LLM (defaultLLMConfig)
import Shikumi.LLM qualified as LLM
import Shikumi.Program (Params (..), Program (..), emptyParams)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
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

preparedFor registered binding = PreparedDecision "preparation" (runCorrelationId "run-1") "workflow-1" 0 "triage" (descriptor (programRef registered)) (toJSON input) (modelDescriptor binding) Nothing

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
        timeoutMicros = 2_000_000,
        callLimit = 10
      }

tests :: TestTree
tests =
  testGroup
    "governed decision runner"
    [ testCase "two real Predict nodes use selected model, schema, credential and individual hooks" do
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
            prepared = (preparedFor twoNodes bindingA) {policy = Just policy.ref} :: PreparedDecision
        result <- runDecisionProgram ((env & #profile .~ (Just policy))) prepared (programRef twoNodes) input
        assertBool "profile refuses actual selected model" (isLeft result)
        observed >>= (@?= [])
        inspect >>= (\calls -> Map.size calls @?= 0),
      testCase "call cap spans both nodes" do
        (hooks, inspect) <- newMemoryCallHooks
        (handler, observed) <- fixture 0 (\_ model options -> success model options input)
        env <- environment twoNodes handler hooks
        result <- runDecisionProgram ((env & #callLimit .~ (1))) (preparedFor twoNodes bindingA) (programRef twoNodes) input
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
        result <- try @TransientBehaviorFailure (runDecisionProgram ((env & #timeoutMicros .~ (20_000))) (preparedFor twoNodes bindingA) (programRef twoNodes) input)
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
forbiddenProfile = ResolvedProfile content (Profile.SanctionedExecutionProfileRef (Profile.ProfileId "runner") (Profile.ProfileVersion "1") (profileDigest content))
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
          prohibitions = (Profile.defaultProhibitions & #defaultedThinkingAllowed .~ (True)),
          limits = Profile.unlimitedProfileLimits,
          minimumEvidenceStrength = Profile.EvidenceRequestedOnly,
          requiredCorrelationFields = [],
          signerRequirements = Profile.noSignerRequirements
        }

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
