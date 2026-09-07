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

import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Context (Context)
import Baikai.Error (BaikaiError, authError, rateLimited)
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Model qualified as Model
import Baikai.Options (Options (..), emptyOptions)
import Baikai.Response (Response (..), emptyResponse, errorResponse)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Settei.Env (envSnapshot, environmentSource)
import Settei.Optparse (CliOverride, DiagnosticMode (NoDiagnostic), cliOverride)
import Shikigami.App.Config
  ( AppConfig (behaviorProvider),
    ProviderSelection (..),
    Role (RunBehaviorRole),
    anthropicApiKeyKey,
    behaviorModelKey,
    behaviorProviderKey,
    environmentBindings,
  )
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Provider (ProfileViolation (..), ProviderCall (ProviderCall), constrainBehaviorEnv, describeProviderSelection, newBehaviorEnvFor, renderProfileViolation)
import Shikigami.Behavior.Run (BehaviorEnv (..), defaultToolTurnLimit, newBehaviorEnv, triggerOnly)
import Shikigami.Behavior.Skill (SkillDir (..), runSkillWith)
import Shikigami.Log qualified as Log
import Shikumi.Tool (mkRegistry)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "behavior provider" [credentialTests, profileConstraintTests, failureTests]

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
          UseAnthropic {} -> assertFailure "an unconfigured process must select the stub"
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
    [ testCase "the complete provider tuple is accepted exactly" do
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
            attemptedModel @?= "stub-v1"
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
            attemptedModel @?= "stub-v1"
            assertProfileViolationNamesDigest resolved violation
          Left other -> assertFailure ("expected ForbiddenCall, got " <> show other)
          Right _ -> assertFailure "expected ForbiddenCall, got an allowed environment"
    ]

envWithThinking :: Profile.ThinkingLevel -> BehaviorEnv -> BehaviorEnv
envWithThinking level BehaviorEnv {runtime, model, options, traceSink, tools, activeOverlays, toolTurnLimit} =
  BehaviorEnv
    { runtime,
      model,
      options = options {thinking = Just level},
      traceSink,
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
                  { Profile.provider = "stub",
                    Profile.api = "stub",
                    Profile.endpointClass = "in-process",
                    Profile.modelId = allowedModel,
                    Profile.thinking = Profile.ThinkingHigh
                  },
            Profile.prohibitions,
            Profile.limits = Profile.unlimitedProfileLimits,
            Profile.minimumEvidenceStrength = Profile.EvidenceModelObserved,
            Profile.requiredCorrelationFields = [],
            Profile.signerRequirements = Profile.noSignerRequirements
          }
      digest = profileDigest content
   in ResolvedProfile
        { profile = content,
          ref = Profile.SanctionedExecutionProfileRef stubProfileId stubProfileVersion digest
        }

defaultThinkingProhibitions :: Profile.Prohibitions
defaultThinkingProhibitions =
  Profile.Prohibitions
    { Profile.aliasesAllowed = False,
      Profile.defaultedThinkingAllowed = True,
      Profile.providerFallbackAllowed = False,
      Profile.modelFallbackAllowed = False,
      Profile.effortClampingAllowed = False,
      Profile.cliTransportsAllowed = False
    }

stubProfileId :: Profile.ProfileId
stubProfileId = Profile.ProfileId "stub-profile"

stubProfileVersion :: Profile.ProfileVersion
stubProfileVersion = Profile.ProfileVersion "1"

assertProfileViolationNamesDigest :: ResolvedProfile -> ProfileViolation -> IO ()
assertProfileViolationNamesDigest ResolvedProfile {ref = Profile.SanctionedExecutionProfileRef _ _ (Profile.ProfileDigest digest)} violation = do
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
          Right value -> value @?= Aeson.object ["reply" Aeson..= ("triaged: billing" :: Text)]
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
  emptyResponse
    { message =
        emptyPayload
          { content = V.singleton (AssistantText (TextContent reply))
          }
    }
  where
    Response {message = emptyPayload} = emptyResponse

failureResponse :: BaikaiError -> Response
failureResponse = errorResponse emptyModel epoch 0

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 7 15) 43200
