{-# LANGUAGE DeriveAnyClass #-}

module Shikigami.CapabilityProviderSpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO)
import Control.Exception qualified as Exception
import Data.Aeson (ToJSON)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Kikan.En.Action (AgentAction (ConnectCapability), actionResource, canonicalResourceText)
import Shikigami.Action.Authorization (ActionAuthorizationFailure (ActionPolicyDenied), ActionAuthorizer (..), allowAllActionAuthorizerForTests)
import Shikigami.Capability.Catalog (ExecutionMode (Durable))
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Capability.Tools
import Shikigami.Log qualified as Log
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (SomeTool (..), ToolRegistry, mkRegistry, mkTool, registryNames)
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
    "capability providers"
    [ toolCompositionTests,
      providerRegistryTests,
      authorizationTests,
      lifecycleTests,
      isolationTests
    ]

toolCompositionTests :: TestTree
toolCompositionTests =
  testGroup
    "collision-safe tool composition"
    [ testCase "two capabilities may expose the same logical name" do
        let result =
              composeCapabilityTools
                emptyRegistry
                [(alphaId, [namedTool "search"]), (betaId, [namedTool "search"])]
        registryNames <$> result
          @?= Right ["overlay__alpha__search", "overlay__beta__search"],
      testCase "a repeated capability group is refused even when its logical names differ" do
        case composeCapabilityTools
          emptyRegistry
          [(alphaId, [namedTool "search"]), (alphaId, [namedTool "read"])] of
          Left err -> err @?= DuplicateCapabilityToolGroup {capability = alphaId}
          Right _ -> assertFailure "expected a repeated capability group to be refused",
      testCase "duplicate logical names inside one capability are refused" do
        case composeCapabilityTools emptyRegistry [(alphaId, [namedTool "search", namedTool "search"])] of
          Left err -> err @?= DuplicateLogicalToolName {capability = alphaId, name = "search"}
          Right _ -> assertFailure "expected duplicate logical names to be refused",
      testCase "an overlay cannot replace a base tool" do
        case composeCapabilityTools
          (mkRegistry [namedTool "overlay__alpha__search"])
          [(alphaId, [namedTool "search"])] of
          Left err -> err @?= FinalToolNameCollision {name = "overlay__alpha__search"}
          Right _ -> assertFailure "expected the base-tool collision to be refused"
    ]

providerRegistryTests :: TestTree
providerRegistryTests =
  testGroup
    "exact provider registry"
    [ testCase "duplicate descriptor keys are refused" do
        let provider = inertProvider alphaDescriptor
        case mkCapabilityProviderRegistry [provider, provider] of
          Left err -> err @?= DuplicateCapabilityProvider {capability = alphaId, revision = revisionOne}
          Right _ -> assertFailure "expected duplicate provider keys to be refused",
      testCase "a missing pinned revision never falls forward" do
        let registry = expectRegistry [inertProvider (mkDescriptor alphaId revisionTwo "search")]
        case resolveProvider registry alphaDescriptor of
          Left err -> err @?= CapabilityProviderUnavailable {capability = alphaId, revision = revisionOne}
          Right _ -> assertFailure "expected the pinned revision to be unavailable",
      testCase "the complete pinned descriptor must match" do
        let actual = mkDescriptor alphaId revisionOne "different"
            registry = expectRegistry [inertProvider actual]
        case resolveProvider registry alphaDescriptor of
          Left err -> err @?= CapabilityProviderDescriptorMismatch {expected = alphaDescriptor, actual}
          Right _ -> assertFailure "expected the public descriptor mismatch to be refused"
    ]

authorizationTests :: TestTree
authorizationTests =
  testGroup
    "per-action authorization"
    [ testCase "a denied exact provider action performs no acquisition IO" do
        events <- newIORef []
        requests <- newIORef []
        let authorizer =
              ActionAuthorizer
                { authorize = \principal action -> do
                    modifyIORef' requests (<> [(principal, action)])
                    pure (Left (ActionPolicyDenied "fixture denial")),
                  kawaSource = "fixture"
                }
            registry = expectRegistry [successfulProvider events "A" alphaDescriptor (Right ())]
        result <-
          withCapabilityOverlays
            Log.silentLogger
            authorizer
            registry
            testScope
            (mkResolvedCapabilitySet [alphaDescriptor])
            emptyRegistry
            (\_ _ -> pure ())
        result
          @?= Left
            CapabilityAuthorizationFailed
              { descriptor = alphaDescriptor,
                authorizationError = ActionPolicyDenied "fixture denial"
              }
        readIORef events >>= (@?= [])
        observed <- readIORef requests
        case observed of
          [(principal, action@ConnectCapability {})] -> do
            principal @?= "principal-test"
            canonicalResourceText (actionResource action) @?= "capability_provider:alpha@v1"
          _ -> assertFailure ("expected one exact connect authorization, got " <> show observed)
    ]

lifecycleTests :: TestTree
lifecycleTests =
  testGroup
    "lease lifecycle"
    [ testCase "normal acquisition releases in LIFO order" do
        events <- newIORef []
        let registry =
              expectRegistry
                [ successfulProvider events "A" alphaDescriptor (Right ()),
                  successfulProvider events "B" betaDescriptor (Right ())
                ]
        result <- runOverlays registry (mkResolvedCapabilitySet [betaDescriptor, alphaDescriptor]) emptyRegistry (\_ _ -> pure ("done" :: Text))
        result @?= Right "done"
        observed <- readIORef events
        observed @?= ["acquire:A", "acquire:B", "release:B", "release:A"],
      testCase "a later acquisition failure rolls earlier leases back" do
        events <- newIORef []
        let registry =
              expectRegistry
                [ successfulProvider events "A" alphaDescriptor (Right ()),
                  failingProvider events "B" betaDescriptor
                ]
        result <- runOverlays registry (mkResolvedCapabilitySet [alphaDescriptor, betaDescriptor]) emptyRegistry (\_ _ -> pure ())
        result @?= Left CapabilityAcquireFailed {descriptor = betaDescriptor, error = CapabilityAcquireError "B unavailable"}
        observed <- readIORef events
        observed @?= ["acquire:A", "acquire:B", "release:A"],
      testCase "a callback exception propagates only after cleanup" do
        events <- newIORef []
        let registry = expectRegistry [successfulProvider events "A" alphaDescriptor (Right ())]
        thrown <-
          Exception.try @SomeException
            (runOverlays registry (mkResolvedCapabilitySet [alphaDescriptor]) emptyRegistry (\_ _ -> throwIO (userError "callback failed") :: IO ()))
        case thrown of
          Left _ -> pure ()
          Right result -> assertFailure ("expected callback exception, got " <> show result)
        observed <- readIORef events
        observed @?= ["acquire:A", "release:A"],
      testCase "timeout cancellation releases every lease" do
        events <- newIORef []
        let registry = expectRegistry [successfulProvider events "A" alphaDescriptor (Right ())]
        timed <-
          timeout
            20000
            (runOverlays registry (mkResolvedCapabilitySet [alphaDescriptor]) emptyRegistry (\_ _ -> threadDelay 200000))
        timed @?= Nothing
        observed <- readIORef events
        observed @?= ["acquire:A", "release:A"],
      testCase "one release failure does not prevent later cleanup" do
        events <- newIORef []
        let releaseError = CapabilityReleaseError "B release failed"
            registry =
              expectRegistry
                [ successfulProvider events "A" alphaDescriptor (Right ()),
                  successfulProvider events "B" betaDescriptor (Left releaseError)
                ]
        result <- runOverlays registry (mkResolvedCapabilitySet [alphaDescriptor, betaDescriptor]) emptyRegistry (\_ _ -> pure ())
        result
          @?= Left
            ( CapabilityReleaseFailures
                [CapabilityReleaseFailure {descriptor = betaDescriptor, error = releaseError}]
            )
        observed <- readIORef events
        observed @?= ["acquire:A", "acquire:B", "release:B", "release:A"],
      testCase "composition failure releases the acquired lease" do
        events <- newIORef []
        let registry = expectRegistry [successfulProvider events "A" alphaDescriptor (Right ())]
            collidingBase = mkRegistry [namedTool "overlay__alpha__search"]
        result <- runOverlays registry (mkResolvedCapabilitySet [alphaDescriptor]) collidingBase (\_ _ -> pure ())
        result @?= Left (CapabilityToolCompositionFailed (FinalToolNameCollision {name = "overlay__alpha__search"}))
        observed <- readIORef events
        observed @?= ["acquire:A", "release:A"]
    ]

isolationTests :: TestTree
isolationTests =
  testGroup
    "derived registry isolation"
    [ testCase "overlapping callbacks see only their own tools and leave the base unchanged" do
        events <- newIORef []
        entered <- newEmptyMVar
        continue <- newEmptyMVar
        alphaResult <- newEmptyMVar
        betaResult <- newEmptyMVar
        let registry =
              expectRegistry
                [ successfulProvider events "A" alphaDescriptor (Right ()),
                  successfulProvider events "B" betaDescriptor (Right ())
                ]
            runOne descriptor' resultVar = do
              result <-
                runOverlays registry (mkResolvedCapabilitySet [descriptor']) emptyRegistry \tools active -> do
                  putMVar entered ()
                  takeMVar continue
                  pure (registryNames tools, active)
              putMVar resultVar result
        _ <- forkIO (runOne alphaDescriptor alphaResult)
        _ <- forkIO (runOne betaDescriptor betaResult)
        takeMVar entered
        takeMVar entered
        putMVar continue ()
        putMVar continue ()
        alpha <- takeMVar alphaResult
        beta <- takeMVar betaResult
        alpha @?= Right (["overlay__alpha__search"], singletonSet alphaId)
        beta @?= Right (["overlay__beta__search"], singletonSet betaId)
        registryNames emptyRegistry @?= []
    ]

runOverlays ::
  CapabilityProviderRegistry ->
  ResolvedCapabilitySet ->
  ToolRegistry ->
  (ToolRegistry -> Set.Set CapabilityId -> IO value) ->
  IO (Either CapabilityRuntimeError value)
runOverlays registry resolved base =
  withCapabilityOverlays Log.silentLogger allowAllActionAuthorizerForTests registry testScope resolved base

testScope :: CapabilityScope
testScope = CapabilityScope {runId = "run-test", principal = "principal-test", mode = Durable}

successfulProvider ::
  IORef [Text] ->
  Text ->
  CapabilityDescriptor ->
  Either CapabilityReleaseError () ->
  CapabilityProvider
successfulProvider events label descriptor' releaseResult =
  CapabilityProvider
    { descriptor = descriptor',
      acquire = \_ -> do
        record events ("acquire:" <> label)
        pure
          ( Right
              CapabilityLease
                { descriptor = descriptor',
                  tools = namedTool <$> descriptorToolNames descriptor',
                  release = record events ("release:" <> label) >> pure releaseResult
                }
          )
    }

failingProvider :: IORef [Text] -> Text -> CapabilityDescriptor -> CapabilityProvider
failingProvider events label descriptor' =
  CapabilityProvider
    { descriptor = descriptor',
      acquire = \_ -> do
        record events ("acquire:" <> label)
        pure (Left (CapabilityAcquireError (label <> " unavailable")))
    }

inertProvider :: CapabilityDescriptor -> CapabilityProvider
inertProvider descriptor' =
  CapabilityProvider
    { descriptor = descriptor',
      acquire = \_ -> pure (Left (CapabilityAcquireError "not used"))
    }

record :: IORef [Text] -> Text -> IO ()
record ref event = modifyIORef' ref (<> [event])

namedTool :: Text -> SomeTool
namedTool name =
  SomeTool
    ( mkTool name "Return the supplied value." \ToolInput {value} ->
        pure ToolOutput {answer = value}
    )

descriptorToolNames :: CapabilityDescriptor -> [Text]
descriptorToolNames CapabilityDescriptor {tools} = nameOf <$> tools
  where
    nameOf CapabilityToolDescriptor {name} = name

mkDescriptor :: CapabilityId -> CapabilityRevision -> Text -> CapabilityDescriptor
mkDescriptor capability revision name =
  CapabilityDescriptor
    { capability,
      revision,
      tools = [CapabilityToolDescriptor {name, operationClass = Observation}]
    }

alphaDescriptor :: CapabilityDescriptor
alphaDescriptor = mkDescriptor alphaId revisionOne "search"

betaDescriptor :: CapabilityDescriptor
betaDescriptor = mkDescriptor betaId revisionOne "search"

alphaId :: CapabilityId
alphaId = expectRight (mkCapabilityId "alpha")

betaId :: CapabilityId
betaId = expectRight (mkCapabilityId "beta")

revisionOne :: CapabilityRevision
revisionOne = expectRight (mkCapabilityRevision "v1")

revisionTwo :: CapabilityRevision
revisionTwo = expectRight (mkCapabilityRevision "v2")

emptyRegistry :: ToolRegistry
emptyRegistry = mkRegistry []

expectRegistry :: [CapabilityProvider] -> CapabilityProviderRegistry
expectRegistry providers =
  case mkCapabilityProviderRegistry providers of
    Left err -> Prelude.error ("invalid test provider registry: " <> show err)
    Right registry -> registry

expectRight :: (Show err) => Either err value -> value
expectRight = \case
  Left err -> Prelude.error (show err)
  Right value -> value

singletonSet :: value -> Set.Set value
singletonSet = Set.singleton
