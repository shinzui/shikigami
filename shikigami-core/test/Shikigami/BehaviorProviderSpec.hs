-- | The skill arm's handling of provider failure.
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

import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Error (BaikaiError, authError, rateLimited)
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Response (Response (..), emptyResponse, errorResponse)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Skill (SkillDir (..), runSkillWith)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "behavior provider failure"
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
--
-- Cabal runs a test suite from its package directory, so the skill is located
-- relative to the repository root rather than the working directory.
runWith :: (Model -> IO Response) -> IO (Either RunError Value)
runWith complete = do
  root <- repositoryRoot
  runSkillWith
    emptyModel
    (SkillDir (root </> "agents" </> "skills" </> "triage-note"))
    Aeson.Null
    (\model _ctx _opts -> complete model)

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
