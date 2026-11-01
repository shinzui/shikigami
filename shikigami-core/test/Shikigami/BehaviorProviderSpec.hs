-- | What the skill arm sends, and what it does with what comes back.
--
-- Two independent things are pinned here, both of which fail silently rather
-- than loudly if they break.
--
-- == Which credential reaches the model call
--
-- The skill arm used to dispatch with a hardcoded empty options record, so the
-- only way a request could authenticate was baikai's own fallback: the Claude
-- handler reading @ANTHROPIC_API_KEY@ out of the process environment. That is a
-- second credential path outside Settei's precedence, provenance, and redaction,
-- and a deployment using it would authenticate as something @--explain-config@
-- never mentioned. The cases below resolve a real configuration through Settei,
-- build the environment a process would build, and read back the options the
-- completion function actually received.
--
-- == Provider failure
--
-- Baikai 0.4 reports a failed call /in band/: the provider returns an
-- error-shaped 'Response' with @stopReason = ErrorReason@, no assistant content,
-- and a classified 'BaikaiError', rather than throwing. A caller that reads only
-- the assistant text therefore turns a rate limit or an auth failure into a
-- successful reply of @""@ — the agent "succeeds", records an empty learning,
-- and dispatches its sinks.
--
-- These cases pin the translation that prevents that. What the worker /does/
-- with a retryable failure — the ceiling, the backoff, honouring
-- @retry_after_seconds@, when to dead-letter — is owned by
-- @docs\/plans\/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md@;
-- what runs the call at all is owned by
-- @docs\/plans\/13-wire-a-real-model-provider-into-behavior-runs.md@. This module
-- only asserts that a failure is a failure and that its retryability survives.
--
-- No API key is involved: 'runSkillWith' takes the completion function as an
-- argument, so the responses below are constructed directly.
module Shikigami.BehaviorProviderSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Compat qualified as Compat
import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Context (Context, emptyContext, systemUser)
import Baikai.Context qualified as Context
import Baikai.Error (BaikaiError, authError, rateLimited)
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Model qualified as Model
import Baikai.Models.Generated (allModels)
import Baikai.Options (Options (..), emptyOptions)
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Baikai.Provider.Registry (ApiProvider (..), completeRequest)
import Baikai.Response (Response (..), emptyResponse, errorResponse, flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.ResponseFormat (ResponseFormat (..), jsonSchemaFormat)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingMinimal))
import Baikai.Tool (ToolChoice (ToolChoiceNone), mkTool)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, finally, try)
import Control.Lens ((&), (.~))
import Control.Monad (unless, void)
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Settei qualified
import Settei.Env (envSnapshot, environmentSource)
import Settei.Optparse (CliOverride, DiagnosticMode (NoDiagnostic), cliOverride)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.DeclarationValue
import Shikigami.App.Config
  ( AppConfig (behaviorProvider),
    ProviderSelection (..),
    Role (RunBehaviorRole),
    anthropicApiKeyKey,
    behaviorModelKey,
    behaviorProviderKey,
    environmentBindings,
    openaiApiKeyKey,
  )
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileFor, resolvedProfileView)
import Shikigami.Behavior.Compatibility
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Provider (ProfileViolation (..), ProviderCall (ProviderCall), constrainBehaviorEnv, describeProviderSelection, newBehaviorEnvFor, providerCall, renderProfileViolation)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Behavior.Run (BehaviorEnv (..), defaultToolTurnLimit, newBehaviorEnv, triggerOnly)
import Shikigami.Behavior.Run qualified as Behavior
import Shikigami.Behavior.Skill (SkillDir (..), runSkillWith)
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Schedule (parseCron)
import Shikumi.Tool (mkRegistry)
import System.Directory (createDirectory, doesFileExist, executable, getPermissions, getTemporaryDirectory, removeDirectoryRecursive, removeFile, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "behavior provider" [credentialTests, profileConstraintTests, failureTests, contractTests, httpDispatchTests]

-- ── Which credential reaches the model call ─────────────────────────────────

-- | A token no default, description, key, or model id contains, so finding it
-- anywhere it does not belong is unambiguous.
sentinelKey :: Text
sentinelKey = "sk-ant-s3cr3t-planted-token-42"

credentialTests :: TestTree
credentialTests =
  testGroup
    "the credential configuration resolved is the one the call carries"
    [ testCase "the Anthropic branch dispatches with the resolved key, not an environment lookup" do
        selection <- selectionFor [cliOverride behaviorProviderKey "anthropic", cliOverride anthropicApiKeyKey sentinelKey]
        env <- newBehaviorEnvFor Log.silentLogger selection Nothing
        envModelId env @?= "claude-sonnet-4-6"
        sent <- capturedOptions env
        -- ApiKeyLiteral, not ApiKeyEnv: baikai must not be left to find a
        -- credential of its own below Settei's composition root.
        apiKey sent @?= Just (ApiKeyLiteral sentinelKey),
      testCase "the chosen model travels with the options" do
        selection <-
          selectionFor
            [ cliOverride behaviorProviderKey "anthropic",
              cliOverride behaviorModelKey "claude-haiku-4-5",
              cliOverride anthropicApiKeyKey sentinelKey
            ]
        env <- newBehaviorEnvFor Log.silentLogger selection Nothing
        envModelId env @?= "claude-haiku-4-5",
      testCase "the stub branch carries no credential at all" do
        selection <- selectionFor []
        case selection of
          UseStub -> pure ()
          _ -> assertFailure "an unconfigured process must select the stub"
        env <- newBehaviorEnvFor Log.silentLogger selection Nothing
        sent <- capturedOptions env
        apiKey sent @?= Nothing,
      -- The description is what the process prints at startup, so it is the one
      -- rendering of a selection that is guaranteed to reach a log.
      testCase "the announced provider names the model and never the key" do
        selection <- selectionFor [cliOverride behaviorProviderKey "anthropic", cliOverride anthropicApiKeyKey sentinelKey]
        let described = describeProviderSelection selection
        assertBool
          ("the description should name the model:\n" <> Text.unpack described)
          ("claude-sonnet-4-6" `Text.isInfixOf` described)
        assertAbsent "the provider description" described
        env <- newBehaviorEnvFor Log.silentLogger selection Nothing
        sent <- capturedOptions env
        assertAbsent "the options' Show rendering" (Text.pack (show sent))
        assertAbsent "the options' JSON rendering" (Text.pack (show (Aeson.encode sent)))
    ]

-- | Resolve a real configuration through Settei and take the provider it chose.
--
-- Deliberately not a hand-built 'ProviderSelection': the thing worth proving is
-- that a value an operator can actually supply arrives at the model call, and a
-- constructor applied by hand would prove nothing about the declaration.
selectionFor :: [CliOverride] -> IO ProviderSelection
selectionFor overrides =
  case (.resolved) run of
    Just config -> pure ((.behaviorProvider) config)
    Nothing ->
      assertFailure
        ("expected a resolved configuration, got exit " <> show ((.exitCode) run) <> ":\n" <> Text.unpack ((.standardError) run))
  where
    run =
      appConfigRun
        RunBehaviorRole
        ConfigOptions {configPaths = [], namedSources = [], overrides, diagnosticMode = NoDiagnostic}
        (Right [])
        (environmentSource environmentBindings (envSnapshot []))

-- | Run a skill through the environment and return the options the completion
-- function was handed.
capturedOptions :: BehaviorEnv -> IO Options
capturedOptions BehaviorEnv {model = envModel, options = envOptions} = do
  seen <- newIORef emptyOptions
  result <-
    runSkillWithFixture
      envModel
      envOptions
      (\_model _ctx opts -> writeIORef seen opts >> pure (textResponse "captured"))
  case result of
    Right _ -> readIORef seen
    Left err -> assertFailure ("the capturing run should succeed, got " <> show err)

-- | The model an environment dispatches with. A plain selector would be
-- ambiguous: 'Baikai.Response.Response' has a @model@ field too.
envModelId :: BehaviorEnv -> Text
envModelId BehaviorEnv {model = envModel} = Model.modelId envModel

runSkillWithFixture ::
  Model ->
  Options ->
  (Model -> Context -> Options -> IO Response) ->
  IO (Either RunError Value)
runSkillWithFixture model options complete = do
  root <- repositoryRoot
  runSkillWith
    model
    options
    (mkRegistry [])
    defaultToolTurnLimit
    (SkillDir (root </> "agents" </> "skills" </> "triage-note"))
    (triggerOnly Aeson.Null)
    complete

assertAbsent :: String -> Text -> IO ()
assertAbsent label rendered =
  assertBool
    (label <> " leaked the planted credential:\n" <> Text.unpack rendered)
    (not ("s3cr3t-planted-token-42" `Text.isInfixOf` rendered))

-- ── Pinned profile constraint ───────────────────────────────────────────────

profileConstraintTests :: TestTree
profileConstraintTests =
  testGroup
    "a pinned profile is checked before provider dispatch"
    [ testCase "all HTTP and CLI surfaces keep exact profile tuples" do
        base <- newBehaviorEnv
        mapM_
          ( \(apiTag, expectedApi, expectedEndpoint) -> do
              let actual = (envWithThinking Profile.ThinkingHigh base) {Behavior.model = (cliModel apiTag) {Model.baseUrl = "https://example.invalid/v1"}}
                  call@(ProviderCall vendor api endpoint model _) = providerCall actual
                  allowed = Profile.AllowedCall vendor api endpoint model Profile.ThinkingHigh
                  profileFor permitsCli value =
                    let template = stubProfile (Coordinate.providerCoordinateText model) ((Profile.defaultProhibitions & #cliTransportsAllowed .~ (PV.permissionFromBool permitsCli)))
                        content = ((resolvedProfileView template).profile & #allowedCalls .~ (NonEmpty.singleton value))
                     in resolvedProfileFor content
              Coordinate.providerCoordinateText api @?= expectedApi
              Coordinate.providerCoordinateText endpoint @?= expectedEndpoint
              case constrainBehaviorEnv (profileFor True allowed) actual of
                Right _ -> pure ()
                Left violation -> assertFailure (show violation)
              mapM_
                ( \mismatch -> case constrainBehaviorEnv (profileFor True mismatch) actual of
                    Left (ForbiddenCall attempted _) -> attempted @?= call
                    Left other -> assertFailure ("expected exact tuple refusal: " <> show other)
                    Right _ -> assertFailure "mismatched tuple was admitted"
                )
                [(allowed & #provider .~ (Coordinate.providerCoordinate "other")), (allowed & #api .~ (Coordinate.providerCoordinate "other")), (allowed & #endpointClass .~ (Coordinate.providerCoordinate "other")), (allowed & #modelId .~ (Coordinate.providerCoordinate "other")), (allowed & #thinking .~ (Profile.ThinkingLow))]
              if Coordinate.providerCoordinateText endpoint == "cli"
                then case constrainBehaviorEnv (profileFor False allowed) actual of
                  Left (CliTransportForbidden attempted _) -> attempted @?= call
                  _ -> assertFailure "CLI prohibition was bypassed"
                else pure ()
              if expectedEndpoint == "https"
                then do
                  let plaintext = (actual & #model .~ ((actual.model & #baseUrl .~ ("http://127.0.0.1:12345/v1"))))
                  providerCall plaintext @?= ProviderCall vendor api (Coordinate.providerCoordinate "http") model (Just Profile.ThinkingHigh)
                  case constrainBehaviorEnv (profileFor True allowed) plaintext of
                    Left (ForbiddenCall _ _) -> pure ()
                    _ -> assertFailure "HTTPS-only profile admitted a plaintext endpoint"
                  case constrainBehaviorEnv (profileFor True ((allowed & #endpointClass .~ (Coordinate.providerCoordinate "http")))) plaintext of
                    Right _ -> pure ()
                    Left violation -> assertFailure (show violation)
                else pure ()
          )
          [(AnthropicMessages, "messages", "https"), (OpenAIChatCompletions, "chat-completions", "https"), (OpenAIResponses, "responses", "https"), (AnthropicMessagesCli, "messages", "cli"), (OpenAICompletionsCli, "completions", "cli")],
      testCase "the complete provider tuple is accepted exactly" do
        env <- newBehaviorEnv
        let constrained = envWithThinking Profile.ThinkingHigh env
        case constrainBehaviorEnv (stubProfile "stub-v1" Profile.defaultProhibitions) constrained of
          Right _ -> pure ()
          Left violation -> assertFailure ("the exact tuple should be allowed, got " <> show violation),
      testCase "a defaulted thinking level is refused when the profile keeps that prohibition" do
        env <- newBehaviorEnv
        let resolved = stubProfile "stub-v1" Profile.defaultProhibitions
        case constrainBehaviorEnv resolved env of
          Left violation@(DefaultedThinkingForbidden (ProviderCall _ _ _ attemptedModel attemptedThinking) _) -> do
            Coordinate.providerCoordinateText attemptedModel @?= "stub-v1"
            attemptedThinking @?= Nothing
            assertProfileViolationNamesDigest resolved violation
          Left other -> assertFailure ("expected DefaultedThinkingForbidden, got " <> show other)
          Right _ -> assertFailure "expected DefaultedThinkingForbidden, got an allowed environment",
      testCase "an explicitly permitted SDK thinking default may dispatch" do
        env <- newBehaviorEnv
        case constrainBehaviorEnv (stubProfile "stub-v1" defaultThinkingProhibitions) env of
          Right _ -> pure ()
          Left violation -> assertFailure ("the explicit default permission should be honored, got " <> show violation),
      testCase "a model outside the pinned tuple is refused with the attempted model and digest" do
        env <- newBehaviorEnv
        let resolved = stubProfile "different-model" Profile.defaultProhibitions
            constrained = envWithThinking Profile.ThinkingHigh env
        case constrainBehaviorEnv resolved constrained of
          Left violation@(ForbiddenCall (ProviderCall _ _ _ attemptedModel _) _) -> do
            Coordinate.providerCoordinateText attemptedModel @?= "stub-v1"
            assertProfileViolationNamesDigest resolved violation
          Left other -> assertFailure ("expected ForbiddenCall, got " <> show other)
          Right _ -> assertFailure "expected ForbiddenCall, got an allowed environment"
    ]

envWithThinking :: Profile.ThinkingLevel -> BehaviorEnv -> BehaviorEnv
envWithThinking level BehaviorEnv {runtime, model, options, traceSink, providerRegistry, tools, activeOverlays, toolTurnLimit} =
  BehaviorEnv
    { runtime,
      model,
      options = (options & #thinking .~ (Just level)),
      traceSink,
      providerRegistry,
      tools,
      activeOverlays,
      toolTurnLimit
    }

stubProfile :: Text -> Profile.Prohibitions -> ResolvedProfile
stubProfile allowedModel prohibitions =
  let content =
        Profile.SanctionedExecutionProfile
          { Profile.profileId = stubProfileId,
            Profile.version = stubProfileVersion,
            Profile.issuer = Profile.Issuer "shinzui/kikan",
            Profile.lifecycle = Profile.Active,
            Profile.validFrom = epoch,
            Profile.validUntil = Nothing,
            Profile.allowedCalls =
              NonEmpty.singleton
                Profile.AllowedCall
                  { Profile.provider = Coordinate.providerCoordinate ("stub"),
                    Profile.api = Coordinate.providerCoordinate ("stub"),
                    Profile.endpointClass = Coordinate.providerCoordinate ("in-process"),
                    Profile.modelId = Coordinate.providerCoordinate (allowedModel),
                    Profile.thinking = Profile.ThinkingHigh
                  },
            Profile.prohibitions,
            Profile.limits = Profile.unlimitedProfileLimits,
            Profile.minimumEvidenceStrength = Profile.EvidenceModelObserved,
            Profile.requiredCorrelationFields = [],
            Profile.signerRequirements = Profile.noSignerRequirements
          }
   in resolvedProfileFor content

defaultThinkingProhibitions :: Profile.Prohibitions
defaultThinkingProhibitions =
  Profile.Prohibitions
    { Profile.aliasesAllowed = PV.Prohibited,
      Profile.defaultedThinkingAllowed = PV.Permitted,
      Profile.providerFallbackAllowed = PV.Prohibited,
      Profile.modelFallbackAllowed = PV.Prohibited,
      Profile.effortClampingAllowed = PV.Prohibited,
      Profile.cliTransportsAllowed = PV.Prohibited
    }

stubProfileId :: Profile.ProfileId
stubProfileId = Profile.ProfileId "stub-profile"

stubProfileVersion :: Profile.ProfileVersion
stubProfileVersion = Profile.ProfileVersion "1"

assertProfileViolationNamesDigest :: ResolvedProfile -> ProfileViolation -> IO ()
assertProfileViolationNamesDigest snapshot violation = do
  let digest = Profile.profileDigestText (resolvedProfileView snapshot).ref.digest
  let rendered = renderProfileViolation violation
  assertBool
    ("violation should name the attempted tuple: " <> Text.unpack rendered)
    ("(provider=stub, api=stub, endpointClass=in-process, model=stub-v1, thinking=" `Text.isInfixOf` rendered)
  assertBool ("violation should name the profile digest: " <> Text.unpack rendered) (digest `Text.isInfixOf` rendered)

-- ── Provider failure ────────────────────────────────────────────────────────

failureTests :: TestTree
failureTests =
  testGroup
    "an in-band provider failure is a failure"
    [ testCase "a successful reply is still a reply" do
        result <- runWith (const (pure (textResponse "triaged: billing")))
        case result of
          Right value -> value @?= Aeson.object ["reply" .= ("triaged: billing" :: Text)]
          Left err -> assertFailure ("expected a reply, got " <> show err),
      testCase "a rate limit is a retryable failure, not an empty reply" do
        result <- runWith (const (pure (failureResponse (rateLimited (Just 30) "slow down"))))
        case result of
          Left (ProviderFailed retryable detail) -> do
            retryable @?= True
            detail @?= "RateLimited (HTTP 429): slow down"
          other -> assertFailure ("expected a retryable provider failure, got " <> show other),
      testCase "an auth failure is a terminal failure, not an empty reply" do
        result <- runWith (const (pure (failureResponse (authError "no credential"))))
        case result of
          Left (ProviderFailed retryable detail) -> do
            retryable @?= False
            detail @?= "AuthError: no credential"
          other -> assertFailure ("expected a terminal provider failure, got " <> show other)
    ]

-- | Run the triage-note skill with an injected completion function.
runWith :: (Model -> IO Response) -> IO (Either RunError Value)
runWith complete =
  runSkillWithFixture emptyModel emptyOptions (\model _ctx _opts -> complete model)

-- | Cabal runs a test suite from its package directory, so the skill fixture is
-- located relative to the repository root rather than the working directory.
repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

textResponse :: Text -> Response
textResponse reply =
  (emptyResponse & #message .~ ((emptyPayload & #content .~ (V.singleton (AssistantText (TextContent reply))))))
  where
    Response {message = emptyPayload} = emptyResponse

failureResponse :: BaikaiError -> Response
failureResponse = errorResponse emptyModel epoch 0

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 7 15) 43200

-- Real public adapters, disposable fake executables, no vendor credentials.
contractTests :: TestTree
contractTests =
  testGroup
    "released batch contracts and promotion gate"
    [ testCase "Claude JSON response decodes through the public provider" $ withFake "printf '%s\\n' '{\"result\":\"marker\",\"is_error\":false}'\n" \dir exe -> do
        resp <- (ClaudeCli.claudeCliProvider ((ClaudeCli.defaultClaudeCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))).complete (cliModel AnthropicMessagesCli) emptyContext emptyOptions
        responseError resp @?= Nothing
        flattenAssistantText (flattenAssistantBlocks resp) @?= "marker",
      testCase "Codex JSONL response decodes through the public provider" $ withFake "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"marker\"}}'\n" \dir exe -> do
        resp <- (CodexCli.codexCliProvider ((CodexCli.defaultCodexCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))).complete (cliModel OpenAICompletionsCli) emptyContext emptyOptions
        responseError resp @?= Nothing
        flattenAssistantText (flattenAssistantBlocks resp) @?= "marker",
      testCase "malformed Claude output remains a classified failure" $ withFake "printf malformed\n" \_ exe -> do
        resp <- (ClaudeCli.claudeCliProvider ((ClaudeCli.defaultClaudeCliConfig & #executable .~ (exe)))).complete (cliModel AnthropicMessagesCli) emptyContext emptyOptions
        assertBool "malformed response refused" (responseError resp /= Nothing),
      testCase "nonzero Codex exit remains a classified failure" $ withFake "exit 7\n" \_ exe -> do
        resp <- (CodexCli.codexCliProvider ((CodexCli.defaultCodexCliConfig & #executable .~ (exe)))).complete (cliModel OpenAICompletionsCli) emptyContext emptyOptions
        assertBool "failed response refused" (responseError resp /= Nothing),
      testCase "released Codex cancellation gap keeps background CLI disabled" $ cancellationGap OpenAICompletionsCli,
      testCase "released Claude cancellation gap keeps background CLI disabled" $ cancellationGap AnthropicMessagesCli,
      testCase "CLI JsonObject refuses before calling a completion" do
        validateResponseRequest (cliModel OpenAICompletionsCli) ((emptyOptions & #responseFormat .~ (Just JsonObject))) emptyContext @?= Left UnsupportedFormat,
      testCase "Anthropic none cannot silently advertise tools" do
        let model = (emptyModel & #api .~ (AnthropicMessages))
            context = (emptyContext & #tools .~ (V.singleton (mkTool "inspect" "public tool" (Aeson.object []))))
        validateResponseRequest model ((emptyOptions & #toolChoice .~ (Just ToolChoiceNone))) context @?= Left (UnsupportedOption "behavior.options.tool_choice")
        validateResponseRequest model ((emptyOptions & #toolChoice .~ (Just ToolChoiceNone))) emptyContext @?= Right (),
      testCase "Anthropic adaptive minimal cannot be clamped to low" do
        case [m | m <- allModels, Model.api m == AnthropicMessages, Model.reasoning m, (Model.anthropicMessagesCompatFor m).thinkingStyle == Compat.AnthropicThinkingAdaptive] of
          model : _ -> validateResponseOptions model ((emptyOptions & #thinking .~ (Just ThinkingMinimal))) @?= Left (UnsupportedOption "behavior.options.thinking")
          [] -> assertFailure "adaptive Anthropic catalog is empty",
      testCase "invalid schema documents and blank names refuse before dispatch" do
        let model = (emptyModel & #api .~ (OpenAIResponses))
        mapM_
          (\format -> validateResponseOptions model ((emptyOptions & #responseFormat .~ (Just format))) @?= Left (UnsupportedOption "behavior.options.response_format"))
          [JsonSchema (jsonSchemaFormat "public" (Aeson.Number 42)), JsonSchema (jsonSchemaFormat "" (Aeson.object []))]
        validateResponseOptions model ((emptyOptions & #responseFormat .~ (Just (JsonSchema (jsonSchemaFormat "public" (Aeson.object [])))))) @?= Right ()
    ]

cliModel :: Api -> Model
cliModel apiTag = (emptyModel & #api .~ (apiTag) & #provider .~ (if apiTag == AnthropicMessagesCli then "anthropic" else "openai") & #modelId .~ ("explicit-fake-model"))

withFake :: String -> (FilePath -> FilePath -> IO a) -> IO a
withFake body run = bracket acquire removeDirectoryRecursive \dir -> do
  let exe = dir </> "vendor"
  writeFile exe ("#!/bin/sh\n" <> body)
  permissions <- getPermissions exe
  setPermissions exe permissions {executable = True}
  run dir exe
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "shikigami-baikai-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path

-- A bounded negative proof of the upstream contract. The fixture owns every
-- PID, cleans up both processes, and times out naturally after five seconds.
-- Change the assertion and remove the gate only after a released fix passes.
cancellationGap :: Api -> IO ()
cancellationGap apiTag = withFake "sleep 5 &\necho $! > child\necho $$ > parent\nwait\n" \dir exe -> do
  finished <- newEmptyMVar
  let provider =
        if apiTag == AnthropicMessagesCli
          then ClaudeCli.claudeCliProvider ((ClaudeCli.defaultClaudeCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))
          else CodexCli.codexCliProvider ((CodexCli.defaultCodexCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))
  worker <- forkIO (void (try @SomeException (provider.complete (cliModel apiTag) emptyContext emptyOptions)) `finally` putMVar finished ())
  let cleanup = do
        mapM_
          ( \file -> do
              exists <- doesFileExist (dir </> file)
              if exists then readFile (dir </> file) >>= \pid -> void (readProcessWithExitCode "/bin/kill" ["-TERM", takeWhile (/= '\n') pid] "") else pure ()
          )
          ["child", "parent"]
        void (timeout 6_000_000 (takeMVar finished))
  flip finally cleanup do
    ready <- timeout 2_000_000 (waitFor (dir </> "child"))
    unless (ready == Just ()) (assertFailure "fake process did not start")
    void (forkIO (killThread worker))
    threadDelay 200_000
    pid <- takeWhile (/= '\n') <$> readFile (dir </> "child")
    (status, _, _) <- readProcessWithExitCode "/bin/kill" ["-0", pid] ""
    status @?= ExitSuccess
    validateResponseOptions (cliModel apiTag) emptyOptions @?= Left BatchCancellationReleaseRequired
  where
    waitFor path = do
      exists <- doesFileExist path
      if exists then pure () else threadDelay 10_000 >> waitFor path

httpDispatchTests :: TestTree
httpDispatchTests =
  testGroup
    "configured HTTP handlers"
    [ httpCase "openai" OpenAIChatCompletions chatFrames,
      httpCase "openai-responses" OpenAIResponses responseFrames
    ]
  where
    httpCase choice apiTag frames = testCase (Text.unpack choice <> " reaches its public Baikai handler") do
      seen <- newEmptyMVar
      let application request respond = do
            body <- Wai.strictRequestBody request
            putMVar seen (Wai.pathInfo request, body)
            respond (Wai.responseLBS status200 [("Content-Type", "text/event-stream")] frames)
          catalog = [m | m <- allModels, Model.api m == apiTag, Model.provider m == "openai"]
      case catalog of
        [] -> assertFailure "released OpenAI catalog is empty"
        model : _ -> testWithApplication (pure application) \port -> do
          selection <- selectionFor [cliOverride behaviorProviderKey choice, cliOverride behaviorModelKey (Model.modelId model), cliOverride openaiApiKeyKey "fake-http-key", cliOverride (stableKeyForTest "behavior.base_url") ("http://127.0.0.1:" <> Text.pack (show port) <> "/v1")]
          env <- newBehaviorEnvFor Log.silentLogger selection Nothing
          resp <- completeRequest env.model (systemUser "system" "marker") env.options
          responseError resp @?= Nothing
          flattenAssistantText (flattenAssistantBlocks resp) @?= "marker"
          (path, body) <- takeMVar seen
          path @?= if apiTag == OpenAIResponses then ["v1", "responses"] else ["v1", "chat", "completions"]
          assertBool "exact configured model sent" (Model.modelId model `Text.isInfixOf` Text.pack (show body))
    chatFrames = "data: {\"id\":\"fake\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"marker\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"fake\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    responseFrames = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fake\",\"output\":[{\"id\":\"msg_fake\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"marker\"}]}]}}\n\n"

stableKeyForTest :: Text -> Settei.Key
stableKeyForTest = either (error . show) id . Settei.parseKey
