{-# LANGUAGE DeriveAnyClass #-}

module Shikigami.BehaviorToolSpec (tests) where

import Baikai.Api (Api (Custom))
import Baikai.Content (AssistantContent (AssistantText, AssistantToolCall), TextContent (..), ToolCall (..), ToolResultContent (ToolResultText), emptyToolCall)
import Baikai.Context (Context)
import Baikai.Context qualified as Context
import Baikai.Evidence qualified as Evidence
import Baikai.Message (Message (ToolResultMessage), ToolResultPayload (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Options (Options, emptyOptions)
import Baikai.Provider (apiProviderWith, registerApiProvider)
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Baikai.Response (Response (..), emptyResponse)
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Tool qualified as WireTool
import Baikai.Trace (TraceEvent (..), TraceSink (..))
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (asyncThreadId, waitCatch, withAsync)
import Control.Exception (AsyncException (ThreadKilled), finally, fromException, throwIO, throwTo)
import Control.Lens ((&), (.~))
import Control.Monad (void)
import Data.Aeson (ToJSON, Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Keiro.Workflow.Types (WorkflowId (..))
import Kikan.En.Action (AgentAction (InvokeCapabilityTool))
import Shikigami.Action.Authorization (ActionAuthorizationFailure (ActionPolicyDenied), ActionAuthorizer (..), allowAllActionAuthorizerForTests)
import Shikigami.Activity.Coordinate
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (Event), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Behavior.Error (FailureClass (..), RunError (..), classifyRunError)
import Shikigami.Behavior.Input (triggerOnly)
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest, defaultToolTurnLimit, newBehaviorEnv, runBehavior, withCapabilityTools)
import Shikigami.Behavior.Skill (SkillDir (..), ToolTurnLimit, parseToolTurnLimit, runSkillWith, toolTurnLimitNumber)
import Shikigami.Capability.Catalog (ExecutionMode (Durable))
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Execution.Coordinate (executionCoordinate)
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Ephemeral (EphemeralResult (..), runEphemeralBehavior)
import Shikigami.Execution.Policy.Limits (PolicyNumber (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Schedule (parseCron)
import Shikumi.Error (ShikumiError (BudgetExceeded))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (SomeTool (..), ToolRegistry, mkRegistry, mkTool, registryNames)
import Shikumi.Tool.Output (textToolOutput)
import Streamly.Data.Fold qualified as Fold
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Prelude

data ToolInput = ToolInput {value :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable ToolInput

data ToolOutput = ToolOutput {answer :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

tests :: TestTree
tests =
  testGroup
    "behavior tools"
    [ emptyRegistryTests,
      toolLoopTests,
      overlayEnvironmentTests,
      bracketedTraceTest,
      cancelledTraceTest,
      failedSinkCancellationTest,
      terminalDrainTraceTest,
      toolInvocationAuthorizationTest,
      ephemeralTests
    ]

ephemeralTests :: TestTree
ephemeralTests =
  testGroup
    "ephemeral harness"
    [ testCase "output repair consumes ordinary model turns and retains observations" do
        calls <- newIORef (0 :: Int)
        (env, decl) <- ephemeralFixture (mkRegistry []) \_ _ _ -> do
          position <- next calls
          pure (textResponse (if position == 0 then "" else "accepted"))
        let policy = defaultHarnessPolicy & #output .~ NonemptyReply & #outputRepairs .~ (fixturePolicy 1)
        result <- runEphemeralBehavior 30 policy env decl (triggerOnly Aeson.Null)
        case result of
          Right accepted -> do
            accepted.output @?= object ["reply" .= ("accepted" :: Text)]
            accepted.modelCalls @?= 2
            accepted.toolCalls @?= 0
          Left err -> assertFailure (show err)
        readIORef calls >>= (@?= 2),
      testCase "tool observations reach the next model turn through the same context codec" do
        calls <- newIORef (0 :: Int)
        seen <- newIORef []
        (env, decl) <- ephemeralFixture namespacedRegistry \_ context _ -> do
          modifyIORef' seen (<> [context])
          position <- next calls
          pure (if position == 0 then toolResponse (call "ephemeral-call" namespacedRead (object ["value" .= ("ephemeral" :: Text)])) else textResponse "done")
        result <- runEphemeralBehavior 30 defaultHarnessPolicy env decl (triggerOnly Aeson.Null)
        case result of
          Right accepted -> accepted.toolCalls @?= 1
          Left err -> assertFailure (show err)
        contexts <- readIORef seen
        case contexts of
          [_, second] -> case toolObservations second of
            (_, _, observation, False) : _ -> observation @?= "{\"answer\":\"saw ephemeral\"}"
            _ -> assertFailure "tool observation missing"
          _ -> assertFailure "expected two model calls",
      testCase "tool denial and human permission stop before the callback" do
        invocations <- newIORef (0 :: Int)
        let registry = mkRegistry [SomeTool (mkTool namespacedRead "Count callbacks." \ToolInput {value} -> unsafeEff_ (modifyIORef' invocations (+ 1)) >> pure (ToolOutput value))]
        (env, decl) <- ephemeralFixture registry (\_ _ _ -> pure (toolResponse (call "held" namespacedRead (object ["value" .= ("private" :: Text)]))))
        mapM_
          ( \policy -> do
              result <- runEphemeralBehavior 30 policy env decl (triggerOnly Aeson.Null)
              case result of Left HarnessPolicyRefused {} -> pure (); _ -> assertFailure "expected permanent policy refusal"
          )
          [defaultHarnessPolicy & #deniedTools .~ (map ExecutionValue.executionCoordinate [namespacedRead]), defaultHarnessPolicy & #humanTools .~ (map ExecutionValue.executionCoordinate [namespacedRead])]
        readIORef invocations >>= (@?= 0),
      testCase "an uncertain native effect is invoked once without automatic retry" do
        invocations <- newIORef (0 :: Int)
        let registry =
              mkRegistry
                [ SomeTool
                    ( mkTool namespacedRead "Uncertain callback." \ToolInput {value} -> do
                        unsafeEff_ (modifyIORef' invocations (+ 1) >> ioError (userError "receipt lost"))
                        pure (ToolOutput value)
                    )
                ]
        (env, decl) <- ephemeralFixture registry (\_ _ _ -> pure (toolResponse (call "uncertain" namespacedRead (object ["value" .= ("private" :: Text)]))))
        result <- runEphemeralBehavior 30 defaultHarnessPolicy env decl (triggerOnly Aeson.Null)
        case result of Left HarnessPolicyRefused {} -> pure (); _ -> assertFailure "expected uncertain outcome refusal"
        readIORef invocations >>= (@?= 1),
      testCase "a repair cannot exceed the model ceiling" do
        calls <- newIORef (0 :: Int)
        (env, decl) <- ephemeralFixture (mkRegistry []) (\_ _ _ -> modifyIORef' calls (+ 1) >> pure (textResponse ""))
        let policy = defaultHarnessPolicy & #maxModelTurns .~ (fixturePolicy 1) & #outputRepairs .~ (fixturePolicy 2) & #output .~ NonemptyReply
        result <- runEphemeralBehavior 30 policy env decl (triggerOnly Aeson.Null)
        result @?= Left (SkillToolTurnLimitExceeded 1)
        readIORef calls >>= (@?= 1)
    ]

ephemeralFixture :: ToolRegistry -> (Model -> Context -> Options -> IO Response) -> IO (BehaviorEnv, AgentDecl)
ephemeralFixture registry complete = do
  root <- repositoryRoot
  let api = Custom "shikigami-ephemeral-fixture"
  providers <- newProviderRegistryFrom [apiProviderWith api (liftCompleteToStream complete) complete]
  base <- newBehaviorEnv
  pure (base & #model .~ toolModel api & #providerRegistry .~ Just providers & #tools .~ registry, declFor [] (Skill (declarationCoordinate ((Text.pack (root </> "agents" </> "skills" </> "triage-note"))))))

emptyRegistryTests :: TestTree
emptyRegistryTests =
  testGroup
    "empty-registry compatibility"
    [ testCase "the original path completes exactly once with no advertised tools" do
        seen <- newIORef []
        result <-
          runSkillFixture (mkRegistry []) defaultToolTurnLimit \_model ctx _options -> do
            modifyIORef' seen (<> [ctx])
            pure (textResponse "unchanged")
        result @?= Right (object ["reply" .= ("unchanged" :: Text)])
        contexts <- readIORef seen
        length contexts @?= 1
        fmap advertisedToolNames contexts @?= [[]]
    ]

toolLoopTests :: TestTree
toolLoopTests =
  testGroup
    "bounded model/tool loop"
    [ testCase "a tool call is dispatched and its result reaches the final turn" do
        seen <- newIORef []
        turn <- newIORef (0 :: Int)
        result <-
          runSkillFixture namespacedRegistry defaultToolTurnLimit \_model ctx _options -> do
            modifyIORef' seen (<> [ctx])
            index <- next turn
            pure
              if index == 0
                then toolResponse (call "call-1" namespacedRead (object ["value" .= ("needle" :: Text)]))
                else textResponse "used the observation"
        result @?= Right (object ["reply" .= ("used the observation" :: Text)])
        contexts <- readIORef seen
        fmap advertisedToolNames contexts @?= [[namespacedRead], [namespacedRead]]
        case contexts of
          [_first, second] ->
            toolObservations second
              @?= [("call-1", namespacedRead, "{\"answer\":\"saw needle\"}", False)]
          _ -> assertFailure ("expected two model contexts, got " <> show (length contexts)),
      testCase "an unknown tool is returned to the model as a recoverable error result" do
        seen <- newIORef []
        turn <- newIORef (0 :: Int)
        result <-
          runSkillFixture namespacedRegistry defaultToolTurnLimit \_model ctx _options -> do
            modifyIORef' seen (<> [ctx])
            index <- next turn
            pure
              if index == 0
                then toolResponse (call "call-missing" "overlay__workspace-read__missing" Aeson.Null)
                else textResponse "recovered"
        result @?= Right (object ["reply" .= ("recovered" :: Text)])
        contexts <- readIORef seen
        case contexts of
          [_first, second] ->
            toolObservations second
              @?= [ ( "call-missing",
                      "overlay__workspace-read__missing",
                      "Error: no such tool \"overlay__workspace-read__missing\".",
                      True
                    )
                  ]
          _ -> assertFailure ("expected two model contexts, got " <> show (length contexts)),
      testCase "a provider that always asks for a tool stops at the default turn limit" do
        calls <- newIORef (0 :: Int)
        result <-
          runSkillFixture namespacedRegistry defaultToolTurnLimit \_model _ctx _options -> do
            index <- next calls
            pure (toolResponse (call ("call-" <> tshow index) namespacedRead (object ["value" .= ("loop" :: Text)])))
        result @?= Left (SkillToolTurnLimitExceeded (toolTurnLimitNumber defaultToolTurnLimit))
        readIORef calls >>= (@?= toolTurnLimitNumber defaultToolTurnLimit),
      testCase "budget exhaustion in a tool remains a permanent infrastructure failure" do
        let budgetRegistry =
              mkRegistry
                [ SomeTool
                    ( mkTool namespacedRead "Exhaust the test budget." \ToolInput {} ->
                        throwError (BudgetExceeded "test budget spent")
                          >> pure ToolOutput {answer = "unreachable"}
                    )
                ]
        result <-
          runSkillFixture budgetRegistry defaultToolTurnLimit \_model _ctx _options ->
            pure (toolResponse (call "call-budget" namespacedRead (object ["value" .= ("ignored" :: Text)])))
        result @?= Left (SkillToolInfrastructureFailed Permanent "budget exceeded: test budget spent")
        classifyRunError (SkillToolInfrastructureFailed Permanent "budget exceeded") @?= Permanent
    ]

overlayEnvironmentTests :: TestTree
overlayEnvironmentTests =
  testGroup
    "run-local overlay guard"
    [ testCase "deriving an environment leaves the base registry and ids unchanged" do
        base <- newBehaviorEnv
        let derived = withCapabilityTools resolvedRead namespacedRegistry base
            BehaviorEnv {tools = baseTools, activeOverlays = baseActive} = base
            BehaviorEnv {tools = derivedTools, activeOverlays = derivedActive} = derived
        registryNames baseTools @?= []
        baseActive @?= Set.empty
        registryNames derivedTools @?= [namespacedRead]
        derivedActive @?= Set.singleton workspaceReadId,
      testCase "empty requests still pass the overlay guard" do
        base <- newBehaviorEnv
        result <- runBehavior base (declFor [] (Deterministic {rule = "not-run", params = Map.empty})) (triggerOnly Aeson.Null)
        result @?= Left (UnsupportedBehavior "Deterministic"),
      testCase "matching requested and active ids pass the overlay guard" do
        base <- newBehaviorEnv
        let derived = withCapabilityTools resolvedRead namespacedRegistry base
        result <- runBehavior derived (declFor [workspaceReadId] (Deterministic {rule = "not-run", params = Map.empty})) (triggerOnly Aeson.Null)
        result @?= Left (UnsupportedBehavior "Deterministic"),
      testCase "missing, extra, and duplicate requests are permanent mismatches" do
        base <- newBehaviorEnv
        let derived = withCapabilityTools resolvedRead namespacedRegistry base
        missing <- runBehavior base (declFor [workspaceReadId] (Deterministic {rule = "not-run", params = Map.empty})) (triggerOnly Aeson.Null)
        extra <- runBehavior derived (declFor [] (Deterministic {rule = "not-run", params = Map.empty})) (triggerOnly Aeson.Null)
        duplicate <- runBehavior derived (declFor [workspaceReadId, workspaceReadId] (Deterministic {rule = "not-run", params = Map.empty})) (triggerOnly Aeson.Null)
        missing @?= Left (CapabilityOverlayMismatch [workspaceReadId] [])
        extra @?= Left (CapabilityOverlayMismatch [] [workspaceReadId])
        duplicate @?= Left (CapabilityOverlayMismatch [workspaceReadId, workspaceReadId] [workspaceReadId])
        classifyRunError (CapabilityOverlayMismatch [workspaceReadId] []) @?= Permanent
    ]

cancelledTraceTest :: TestTree
cancelledTraceTest =
  testCase "behavior cancellation delivers one abort terminal before the original exception returns" do
    ready <- newEmptyMVar
    held <- newEmptyMVar
    traceEvents <- newIORef []
    let api = Custom "shikigami-behavior-cancel-trace"
        model = toolModel api
        handler _ _ _ = putMVar ready () >> takeMVar held
        sink = TraceSink (Fold.drainMapM (\event -> modifyIORef' traceEvents (<> [event])))
    registry <- newProviderRegistryFrom [apiProviderWith api (liftCompleteToStream handler) handler]
    base <- newBehaviorEnv
    let env = base & #providerRegistry .~ Just registry & #traceSink .~ Just sink
        options = emptyOptions & #evidence .~ Just (Evidence.evidenceRequest "behavior-cancel")
    withAsync (completeBehaviorRequest env model Context.emptyContext options) \worker -> do
      timeout 5000000 (takeMVar ready) >>= (@?= Just ())
      -- Throw the specific asynchronous exception through the application boundary.
      -- Reading the sink immediately after joining detects GC-delayed finalization.
      throwTo (asyncThreadId worker) ThreadKilled
      outcome <- timeout 5000000 (waitCatch worker)
      case outcome of
        Just (Left err) -> fromException err @?= Just ThreadKilled
        _ -> assertFailure "cancelled behavior did not return its original exception"
      observed <- readIORef traceEvents
      length [() | CallStarted {} <- observed] @?= 1
      length [() | CallFailed {} <- observed] @?= 1
      length [() | CallFinished {} <- observed] @?= 0
      [evidence.status | CallEvidence {evidence} <- observed] @?= [Evidence.CallAborted]
      case observed of
        [CallStarted {eventId = started}, CallEvidence {eventId = evidenced}, CallFailed {eventId = failed}] ->
          (evidenced, failed) @?= (started, started)
        _ -> assertFailure "abort evidence must precede exactly one terminal"

failedSinkCancellationTest :: TestTree
failedSinkCancellationTest =
  testCase "a failed trace sink cannot replace behavior cancellation" do
    ready <- newEmptyMVar
    held <- newEmptyMVar
    sinkFailed <- newEmptyMVar
    let api = Custom "shikigami-behavior-failed-sink"
        model = toolModel api
        handler _ _ _ = putMVar ready () >> takeMVar held
        sink = TraceSink (Fold.drainMapM (\_ -> putMVar sinkFailed () >> throwIO (userError "public fixture sink failure")))
    registry <- newProviderRegistryFrom [apiProviderWith api (liftCompleteToStream handler) handler]
    base <- newBehaviorEnv
    let env = base & #providerRegistry .~ Just registry & #traceSink .~ Just sink
    withAsync (completeBehaviorRequest env model Context.emptyContext emptyOptions) \worker -> do
      timeout 5000000 (takeMVar ready) >>= (@?= Just ())
      timeout 5000000 (takeMVar sinkFailed) >>= (@?= Just ())
      throwTo (asyncThreadId worker) ThreadKilled
      outcome <- timeout 5000000 (waitCatch worker)
      case outcome of
        Just (Left err) -> fromException err @?= Just ThreadKilled
        _ -> assertFailure "failed sink lost original cancellation or exceeded cleanup bound"

terminalDrainTraceTest :: TestTree
terminalDrainTraceTest =
  testCase "cancellation during a stalled terminal drain stays bounded and preserves the committed terminal" do
    draining <- newEmptyMVar
    release <- newEmptyMVar
    traceEvents <- newIORef []
    let api = Custom "shikigami-behavior-terminal-drain"
        model = toolModel api
        handler _ _ _ = pure (textResponse "committed")
        record event = do
          modifyIORef' traceEvents (<> [event])
          case event of
            CallFinished {} -> putMVar draining () >> takeMVar release
            _ -> pure ()
        sink = TraceSink (Fold.drainMapM record)
    registry <- newProviderRegistryFrom [apiProviderWith api (liftCompleteToStream handler) handler]
    base <- newBehaviorEnv
    let env = base & #providerRegistry .~ Just registry & #traceSink .~ Just sink
    ( withAsync (completeBehaviorRequest env model Context.emptyContext emptyOptions) \worker -> do
        timeout 5000000 (takeMVar draining) >>= (@?= Just ())
        throwTo (asyncThreadId worker) ThreadKilled
        outcome <- timeout 5000000 (waitCatch worker)
        case outcome of
          Just (Left err) -> fromException err @?= Just ThreadKilled
          _ -> assertFailure "stalled trace cleanup lost cancellation or exceeded its bound"
        observed <- readIORef traceEvents
        length [() | CallStarted {} <- observed] @?= 1
        length [() | CallFinished {} <- observed] @?= 1
        length [() | CallFailed {} <- observed] @?= 0
      )
      `finally` void (tryPutMVar release ())

bracketedTraceTest :: TestTree
bracketedTraceTest =
  testCase "a bracketed Skill traces both model turns and releases after the final reply" do
    root <- repositoryRoot
    events <- newIORef ([] :: [Text])
    contexts <- newIORef []
    turns <- newIORef (0 :: Int)
    traceEvents <- newIORef []
    let api = Custom "shikigami-behavior-tool-trace"
        model = toolModel api
        handler _model ctx _options = do
          modifyIORef' contexts (<> [ctx])
          index <- next turns
          pure
            if index == 0
              then toolResponse (call "call-e2e" namespacedRead (object ["value" .= ("e2e" :: Text)]))
              else textResponse "end to end"
        sink = TraceSink (Fold.drainMapM (\event -> modifyIORef' traceEvents (<> [event])))
        provider =
          CapabilityProvider
            { descriptor = readDescriptor,
              acquire = \_scope -> do
                modifyIORef' events (<> ["acquire"])
                pure
                  ( Right
                      CapabilityLease
                        { descriptor = readDescriptor,
                          tools = [logicalReadTool],
                          release = modifyIORef' events (<> ["release"]) >> pure (Right ())
                        }
                  )
            }
        providers = expectRight (mkCapabilityProviderRegistry [provider])
    registerApiProvider (apiProviderWith api (liftCompleteToStream handler) handler)
    base <- newBehaviorEnv
    let tracedBase = base & #model .~ model & #traceSink .~ Just sink
        decl = declFor [workspaceReadId] (Skill {path = declarationCoordinate (Text.pack (root </> "agents" </> "skills" </> "triage-note"))})
    result <-
      withCapabilityOverlays
        Log.silentLogger
        allowAllActionAuthorizerForTests
        providers
        CapabilityScope {runId = WorkflowRun (WorkflowId "run-e2e"), principal = declarationCoordinate "principal-e2e", mode = Durable}
        resolvedRead
        (mkRegistry [])
        (\registry _active -> runBehavior (withCapabilityTools resolvedRead registry tracedBase) decl (triggerOnly Aeson.Null))
    result @?= Right (Right (object ["reply" .= ("end to end" :: Text)]))
    readIORef events >>= (@?= ["acquire", "release"])
    observedContexts <- readIORef contexts
    length observedContexts @?= 2
    case observedContexts of
      [_first, second] ->
        toolObservations second
          @?= [("call-e2e", namespacedRead, "{\"answer\":\"saw e2e\"}", False)]
      _ -> assertFailure ("expected two model contexts, got " <> show (length observedContexts))
    observedTrace <- readIORef traceEvents
    length [() | CallStarted {} <- observedTrace] @?= 2
    length [() | CallFinished {} <- observedTrace] @?= 2

toolInvocationAuthorizationTest :: TestTree
toolInvocationAuthorizationTest = testGroup "exact leased tool authorization" [toolInvocationAuthorizationCase False, toolInvocationAuthorizationCase True]

toolInvocationAuthorizationCase :: Bool -> TestTree
toolInvocationAuthorizationCase dynamic =
  testCase (if dynamic then "dynamic callback is denied" else "typed callback is denied") do
    root <- repositoryRoot
    invocations <- newIORef (0 :: Int)
    authorizations <- newIORef ([] :: [AgentAction])
    turns <- newIORef (0 :: Int)
    let ActionAuthorizer {authorize = allowFixture} = allowAllActionAuthorizerForTests
        authorizer =
          ActionAuthorizer
            { authorize = \principal action -> do
                modifyIORef' authorizations (<> [action])
                case action of
                  InvokeCapabilityTool {} -> pure (Left (ActionPolicyDenied "tool fixture denial"))
                  _ -> allowFixture principal action,
              kawaSource = (activityCoordinate "fixture")
            }
        guardedTool =
          if dynamic
            then
              DynTool
                "read"
                "Dynamic read."
                (object [])
                ( \_ -> do
                    unsafeEff_ (modifyIORef' invocations (+ 1))
                    pure (Right (textToolOutput "dynamic result"))
                )
            else
              SomeTool
                ( mkTool "read" "Record and return the supplied value." \ToolInput {value} -> do
                    unsafeEff_ (modifyIORef' invocations (+ 1))
                    pure ToolOutput {answer = "saw " <> value}
                )
        provider =
          CapabilityProvider
            { descriptor = readDescriptor,
              acquire = \_scope ->
                pure
                  ( Right
                      CapabilityLease
                        { descriptor = readDescriptor,
                          tools = [guardedTool],
                          release = pure (Right ())
                        }
                  )
            }
        providers = expectRight (mkCapabilityProviderRegistry [provider])
        api = Custom (if dynamic then "shikigami-behavior-tool-authorization-dynamic" else "shikigami-behavior-tool-authorization-typed")
        model = toolModel api
        handler _model _ctx _options = do
          turn <- next turns
          pure
            if turn == 0
              then toolResponse (call "call-denied" namespacedRead (object ["value" .= ("secret" :: Text)]))
              else textResponse "handled denial"
    registerApiProvider (apiProviderWith api (liftCompleteToStream handler) handler)
    base <- newBehaviorEnv
    let env = base & #model .~ model
        decl = declFor [workspaceReadId] (Skill {path = declarationCoordinate (Text.pack (root </> "agents" </> "skills" </> "triage-note"))})
    result <-
      withCapabilityOverlays
        Log.silentLogger
        authorizer
        providers
        CapabilityScope {runId = WorkflowRun (WorkflowId "run-denied"), principal = declarationCoordinate "principal-denied", mode = Durable}
        resolvedRead
        (mkRegistry [])
        (\registry _active -> runBehavior (withCapabilityTools resolvedRead registry env) decl (triggerOnly Aeson.Null))
    result @?= Right (Right (object ["reply" .= ("handled denial" :: Text)]))
    readIORef invocations >>= (@?= 0)
    observed <- readIORef authorizations
    case observed of
      [_connect, InvokeCapabilityTool {}] -> pure ()
      _ -> assertFailure ("expected connect then invoke authorization, got " <> show observed)

runSkillFixture ::
  ToolRegistry ->
  ToolTurnLimit ->
  (Model -> Context -> Options -> IO Response) ->
  IO (Either RunError Value)
runSkillFixture registry turnLimit complete = do
  root <- repositoryRoot
  runSkillWith
    emptyModel
    emptyOptions
    registry
    turnLimit
    (SkillDir (root </> "agents" </> "skills" </> "triage-note"))
    (triggerOnly Aeson.Null)
    complete

advertisedToolNames :: Context -> [Text]
advertisedToolNames ctx =
  WireTool.name <$> V.toList (Context.tools ctx)

toolObservations :: Context -> [(Text, Text, Text, Bool)]
toolObservations ctx =
  [ (toolCallId, toolName, text, isError)
  | ToolResultMessage ToolResultPayload {toolCallId, toolName, content, isError} <- V.toList (Context.messages ctx),
    ToolResultText (TextContent text) <- V.toList content
  ]

textResponse :: Text -> Response
textResponse reply =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantText (TextContent reply))
    & #message . #stopReason .~ Stop

toolResponse :: ToolCall -> Response
toolResponse toolCall =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantToolCall toolCall)
    & #message . #stopReason .~ ToolUse

call :: Text -> Text -> Value -> ToolCall
call callId toolName arguments =
  emptyToolCall
    & #id_ .~ callId
    & #name .~ toolName
    & #arguments .~ arguments

logicalReadTool :: SomeTool
logicalReadTool =
  SomeTool
    ( mkTool "read" "Return the supplied value." \ToolInput {value} ->
        pure ToolOutput {answer = "saw " <> value}
    )

namespacedRegistry :: ToolRegistry
namespacedRegistry =
  mkRegistry
    [ SomeTool
        ( mkTool namespacedRead "Return the supplied value." \ToolInput {value} ->
            pure ToolOutput {answer = "saw " <> value}
        )
    ]

namespacedRead :: Text
namespacedRead = "overlay__workspace-read__read"

workspaceReadId :: CapabilityId
workspaceReadId = expectRight (mkCapabilityId "workspace.read")

revisionOne :: CapabilityRevision
revisionOne = expectRight (mkCapabilityRevision "v1")

readDescriptor :: CapabilityDescriptor
readDescriptor =
  CapabilityDescriptor
    { capability = workspaceReadId,
      revision = revisionOne,
      tools = [CapabilityToolDescriptor {name = (executionCoordinate "read"), operationClass = Observation}]
    }

resolvedRead :: ResolvedCapabilitySet
resolvedRead = mkResolvedCapabilitySet [readDescriptor]

declFor :: [CapabilityId] -> Behavior -> AgentDecl
declFor capabilityOverlays behavior =
  AgentDecl
    { name = fixtureAgentName "behavior-tool-test",
      description = "exercise run-local model tools",
      trigger = Event (declarationCoordinate ("test")),
      behavior,
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

toolModel :: Api -> Model
toolModel api =
  emptyModel
    & #modelId .~ "behavior-tool-model"
    & #api .~ api
    & #provider .~ "behavior-tool-provider"
    & #maxOutputTokens .~ 32

next :: IORef Int -> IO Int
next ref = atomicModifyIORef' ref (\value -> (value + 1, value))

expectRight :: (Show err) => Either err value -> value
expectRight = \case
  Left err -> Prelude.error (show err)
  Right value -> value

tshow :: (Show value) => value -> Text
tshow = Text.pack . show

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

fixturePolicy :: (PolicyNumber a) => Integer -> a
fixturePolicy number = either (error . show) id (parsePolicyNumber number)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
