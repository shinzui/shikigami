module Shikigami.Agent.Capability.OneOffSpec (tests) where

import Baikai.Api (Api (Custom))
import Baikai.Content
  ( AssistantContent (AssistantText, AssistantToolCall),
    TextContent (..),
    ToolCall,
    ToolResultContent (ToolResultText),
    emptyToolCall,
  )
import Baikai.Context (Context)
import Baikai.Context qualified as Context
import Baikai.Message (Message (ToolResultMessage), ToolResultPayload (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Options (Options)
import Baikai.Provider (ApiProvider, apiProviderWith, registerApiProvider)
import Baikai.Response (Response, emptyResponse)
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Tool qualified as WireTool
import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Capability.OneOff
import Shikigami.Agent.Capability.Workspace (workspaceReadId)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    IdentityDecl (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv, runBehavior, triggerOnly)
import Shikigami.Capability.Catalog (CapabilityResolutionError (MissingCapabilityIdentity))
import Shikigami.Capability.Overlay (CapabilityId, capabilityIdText)
import Shikigami.Log qualified as Log
import Shikumi.Tool qualified as Tool
import System.Directory
  ( createDirectory,
    doesFileExist,
    getTemporaryDirectory,
    removeFile,
    removePathForcibly,
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data RepositoryFixture = RepositoryFixture
  { container :: !FilePath,
    repository :: !FilePath,
    outsideFile :: !FilePath
  }

tests :: TestTree
tests =
  testGroup
    "one-off capability composition"
    [ testCase "an empty request does not inspect even a missing workspace" do
        base <- newBehaviorEnv
        result <-
          withOneOffCapabilityOverlays
            Log.silentLogger
            allowAllActionAuthorizerForTests
            (Just "/definitely/missing/shikigami-workspace")
            (declFor [])
            base
            (\BehaviorEnv {tools, activeOverlays} -> pure (WireTool.name <$> Vector.toList (registryBaikai tools), activeOverlays))
        result @?= Right ([], Set.empty),
      testCase "the durable CLI runtime also skips workspace discovery for an empty request" do
        result <-
          oneOffCapabilityRuntime
            (Just "/definitely/missing/shikigami-workspace")
            (declFor [])
        case result of
          Left err -> assertFailure ("empty durable runtime was refused: " <> show err)
          Right _runtime -> pure (),
      testCase "the durable CLI runtime authorizes the requested observation overlay" $
        withRepository \RepositoryFixture {repository} -> do
          let decl = declFor [workspaceReadId]
          runtimeResult <- oneOffCapabilityRuntime (Just repository) decl
          case runtimeResult of
            Left err -> assertFailure ("durable runtime was not constructed: " <> show err)
            Right runtime ->
              case AgentWorkflow.resolveCapabilitiesForRun runtime decl Nothing of
                Left err -> assertFailure ("durable overlay was not authorized: " <> show err)
                Right _resolved -> pure (),
      testCase "a missing identity is refused before workspace discovery" do
        base <- newBehaviorEnv
        result <-
          withOneOffCapabilityOverlays
            Log.silentLogger
            allowAllActionAuthorizerForTests
            (Just "/definitely/missing/shikigami-workspace")
            (declForIdentity Nothing [workspaceReadId])
            base
            (\_ -> pure ())
        result @?= Left (OneOffResolutionRefused MissingCapabilityIdentity),
      testCase "the checked-in proof manifests share behavior and identity but differ in opt-in" do
        root <- repositoryRoot
        requested <- loadAgent (root </> "agents" </> "proof" </> "workspace-read.dhall")
        disabled <- loadAgent (root </> "agents" </> "proof" </> "workspace-read-disabled.dhall")
        case (requested, disabled) of
          (Right requestedDecl, Right disabledDecl) -> do
            fmap capabilityIdText ((.capabilityOverlays) requestedDecl) @?= ["workspace.read"]
            (.capabilityOverlays) disabledDecl @?= []
            (.behavior) requestedDecl @?= (.behavior) disabledDecl
            (.identity) requestedDecl @?= (.identity) disabledDecl
          other -> assertFailure ("proof manifests did not load: " <> show other),
      testCase "only the opted-in agent receives tools through the scripted model loop" $
        withRepository \RepositoryFixture {repository, outsideFile} -> do
          root <- repositoryRoot
          fixtureBefore <- BS.readFile (repository </> "note.txt")
          outsideBefore <- BS.readFile outsideFile
          events <- newIORef ([] :: [ByteString])
          optedContexts <- newIORef []
          optedTurns <- newIORef (0 :: Int)
          emptyContexts <- newIORef []
          let logger = Log.Logger {minLevel = Log.Info, sink = \line -> modifyIORef' events (<> [line])}
              optedApi = Custom "workspace-overlay-opted-test"
              emptyApi = Custom "workspace-overlay-empty-test"
              optedHandler _model context _options = do
                modifyIORef' optedContexts (<> [context])
                turn <- next optedTurns
                pure
                  if turn == 0
                    then toolResponse (call "workspace-read" namespacedRead (object ["path" .= ("note.txt" :: Text)]))
                    else textResponse "used workspace observation"
              emptyHandler _model context _options = do
                modifyIORef' emptyContexts (<> [context])
                pure (textResponse "ran without workspace tools")
          registerApiProvider (apiProvider optedApi optedHandler)
          registerApiProvider (apiProvider emptyApi emptyHandler)
          base <- newBehaviorEnv
          let optedBase = (base & #model .~ (toolModel optedApi))
              emptyBase = (base & #model .~ (toolModel emptyApi))
              optedDecl = (declFor [workspaceReadId]) {behavior = Skill {path = Text.pack (root </> "agents" </> "skills" </> "triage-note")}}
              emptyDecl = (declFor []) {behavior = Skill {path = Text.pack (root </> "agents" </> "skills" </> "triage-note")}}
          opted <-
            withOneOffCapabilityOverlays logger allowAllActionAuthorizerForTests (Just repository) optedDecl optedBase \derived ->
              runBehavior derived optedDecl (triggerOnly (object ["task" .= ("read the fixture" :: Text)]))
          empty <-
            withOneOffCapabilityOverlays
              logger
              allowAllActionAuthorizerForTests
              (Just "/definitely/missing/shikigami-workspace")
              emptyDecl
              emptyBase
              (\derived -> runBehavior derived emptyDecl (triggerOnly (object ["task" .= ("try the same tool" :: Text)])))
          opted @?= Right (Right (object ["reply" .= ("used workspace observation" :: Text)]))
          empty @?= Right (Right (object ["reply" .= ("ran without workspace tools" :: Text)]))
          contexts <- readIORef optedContexts
          fmap advertisedToolNames contexts
            @?= [ [namespacedGlob, namespacedGrep, namespacedRead],
                  [namespacedGlob, namespacedGrep, namespacedRead]
                ]
          case contexts of
            [_first, second] ->
              assertBool
                "the tool observation did not contain the workspace fixture"
                ("needle" `Text.isInfixOf` Text.concat [text | (_, _, text, _) <- toolObservations second])
            _ -> assertFailure ("expected two opted-in model turns, got " <> show (length contexts))
          emptySeen <- readIORef emptyContexts
          fmap advertisedToolNames emptySeen @?= [[]]
          renderedEvents <- TE.decodeUtf8 . BS.concat <$> readIORef events
          mapM_
            (\event -> assertBool ("missing lifecycle event " <> Text.unpack event) (event `Text.isInfixOf` renderedEvents))
            [ "capability.overlay.acquired",
              "capability.overlay.released"
            ]
          assertBool "lifecycle logs must not contain file contents" (not ("needle" `Text.isInfixOf` renderedEvents))
          BS.readFile (repository </> "note.txt") >>= (@?= fixtureBefore)
          BS.readFile outsideFile >>= (@?= outsideBefore)
    ]

declFor :: [CapabilityId] -> AgentDecl
declFor = declForIdentity (Just IdentityDecl {principal = "principal_workspace_scripted"})

declForIdentity :: Maybe IdentityDecl -> [CapabilityId] -> AgentDecl
declForIdentity identity capabilityOverlays =
  AgentDecl
    { name = "workspace-scripted-agent",
      description = "workspace scripted agent",
      trigger = Event {eventType = "test"},
      behavior = Skill {path = "unused"},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays,
      identity,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

apiProvider :: Api -> (Model -> Context -> Options -> IO Response) -> ApiProvider
apiProvider tag handler = apiProviderWith tag (liftCompleteToStream handler) handler

toolModel :: Api -> Model
toolModel api =
  emptyModel
    & #modelId .~ "workspace-overlay-test-model"
    & #api .~ api
    & #provider .~ "workspace-overlay-test-provider"
    & #maxOutputTokens .~ 32

textResponse :: Text -> Response
textResponse reply =
  emptyResponse
    & #message . #content .~ Vector.singleton (AssistantText (TextContent reply))
    & #message . #stopReason .~ Stop

toolResponse :: ToolCall -> Response
toolResponse toolCall =
  emptyResponse
    & #message . #content .~ Vector.singleton (AssistantToolCall toolCall)
    & #message . #stopReason .~ ToolUse

call :: Text -> Text -> Value -> ToolCall
call callId toolName arguments =
  emptyToolCall
    & #id_ .~ callId
    & #name .~ toolName
    & #arguments .~ arguments

advertisedToolNames :: Context -> [Text]
advertisedToolNames context =
  WireTool.name <$> Vector.toList (Context.tools context)

toolObservations :: Context -> [(Text, Text, Text, Bool)]
toolObservations context =
  [ (toolCallId, toolName, text, isError)
  | ToolResultMessage ToolResultPayload {toolCallId, toolName, content, isError} <- Vector.toList (Context.messages context),
    ToolResultText (TextContent text) <- Vector.toList content
  ]

registryBaikai :: Tool.ToolRegistry -> Vector.Vector WireTool.Tool
registryBaikai = Tool.registryBaikai

next :: IORef Int -> IO Int
next ref = atomicModifyIORef' ref (\value -> (value + 1, value))

withRepository :: (RepositoryFixture -> IO value) -> IO value
withRepository = bracket createRepository (removePathForcibly . (.container))

createRepository :: IO RepositoryFixture
createRepository = do
  temporary <- getTemporaryDirectory
  (allocated, handle) <- openTempFile temporary "shikigami-overlay-scripted-test"
  hClose handle
  removeFile allocated
  createDirectory allocated
  let repository = allocated </> "repo"
      outsideFile = allocated </> "outside.txt"
  createDirectory repository
  callProcess "git" ["-C", repository, "init", "-q"]
  BS.writeFile (repository </> "note.txt") "alpha needle omega\n"
  BS.writeFile outsideFile "outside remains untouched\n"
  pure RepositoryFixture {container = allocated, repository, outsideFile}

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

namespacedRead :: Text
namespacedRead = "overlay__workspace-read__read"

namespacedGrep :: Text
namespacedGrep = "overlay__workspace-read__grep"

namespacedGlob :: Text
namespacedGlob = "overlay__workspace-read__glob"
