-- Coupled database/receipt recovery with an instrumented Unix interpreter.
-- Native ownership and service access are separately qualified in Apple Linux;
-- these tests do not create accounts or claim real Unix provisioning evidence.
module Shikigami.WorkspaceProvisionSpec (tests) where

import Control.Exception (throwIO)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.Allocation (workspaceMetadata)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.Provision
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceProcessProfileSpec (withProfiles)
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace coupled provisioning"
    [ testCase "retains one reserved identity and ready receipt across duplicate delivery" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        profile <- right =<< provisionWorkspaceProfile runtime binding admission policy pool
        provisionWorkspaceProfile runtime binding admission policy pool >>= (@?= Right profile)
        run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right (Just (profile, ProfileReady)))
        readIORef counts >>= (@?= (1, 2)),
      testCase "denied exact authority never creates an account, changes ownership or writes an intent receipt" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        provisionWorkspaceProfile (runtime & #authorizer .~ denyAllActionAuthorizer) binding admission policy pool >>= (@?= Left ProvisionRefused)
        readIORef counts >>= (@?= (0, 0))
        doesPathExist (workspaceMetadata binding.storageRoot binding </> "profile-provision.json") >>= (@?= False)
        Right (Just (_, state)) <- run env (inspectProcessProfileTx binding.workspace)
        state @?= ProfileReserved,
      testCase "lost account acknowledgement recovers the original identity rather than creating another" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        let lost =
              runtime
                & #backend
                . #createIdentity
                .~ ( \authorize profile -> do
                       result <- runtime.backend.createIdentity authorize profile
                       case result of Right () -> pure (Left ProvisionUnresolved); _ -> pure result
                   )
        provisionWorkspaceProfile lost binding admission policy pool >>= (@?= Left ProvisionUnresolved)
        Right (Just (original, ProfileReserved)) <- run env (inspectProcessProfileTx binding.workspace)
        completed <- right =<< provisionWorkspaceProfile runtime binding admission policy pool
        completed @?= original
        readIORef counts >>= (@?= (1, 2)),
      testCase "an interrupted tree application resumes under the same reserved identity" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        failOnce <- newIORef True
        let interrupted =
              runtime
                & #backend
                . #tree
                .~ ( \uid apply target -> do
                       result <- runtime.backend.tree uid apply target
                       first <- if apply then atomicModifyIORef' failOnce (\old -> (False, old)) else pure False
                       if first then throwIO (userError "fixture ownership acknowledgement lost") else pure result
                   )
        provisionWorkspaceProfile interrupted binding admission policy pool >>= (@?= Left ProvisionUnresolved)
        Right (Just (original, ProfileReserved)) <- run env (inspectProcessProfileTx binding.workspace)
        provisionWorkspaceProfile runtime binding admission policy pool >>= (@?= Right original)
        readIORef counts >>= (@?= (1, 3)),
      testCase "a ready private receipt recovers a missing database acknowledgement without repeating Unix effects" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        let interrupted = runtime & #backend . #afterReady .~ throwIO (userError "fixture ready acknowledgement lost")
        provisionWorkspaceProfile interrupted binding admission policy pool >>= (@?= Left ProvisionUnresolved)
        Right (Just (original, ProfileReserved)) <- run env (inspectProcessProfileTx binding.workspace)
        provisionWorkspaceProfile runtime binding admission policy pool >>= (@?= Right original)
        readIORef counts >>= (@?= (1, 2)),
      testCase "an existing identity without this provider's prepared receipt cannot be adopted" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, identity, counts) <- fakeRuntime env
        writeIORef identity IdentityReady
        provisionWorkspaceProfile runtime binding admission policy pool >>= (@?= Left ProvisionRefused)
        readIORef counts >>= (@?= (0, 0))
        doesPathExist (workspaceMetadata binding.storageRoot binding </> "profile-provision.json") >>= (@?= False),
      testCase "unsupported hosts and revoked lifecycle refuse before identity reservation or native effects" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        enroll env binding
        (runtime, _, counts) <- fakeRuntime env
        provisionWorkspaceProfile (runtime & #backend . #bootIdentity .~ pure (Left Systemd.SystemdUnsupported)) binding admission policy pool >>= (@?= Left ProvisionUnsupported)
        provisionWorkspaceProfile (runtime & #current .~ pure (Left "revoked")) binding admission policy pool >>= (@?= Left ProvisionRefused)
        run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right Nothing)
        readIORef counts >>= (@?= (0, 0))
    ]

fakeRuntime :: AppEnv -> IO (ProvisionRuntime, IORef ManagedIdentity, IORef (Int, Int))
fakeRuntime env = do
  identity <- newIORef IdentityMissing
  counts <- newIORef (0, 0)
  let create authorize _ = do
        allowed <- authorize
        case allowed of
          Left err -> pure (Left err)
          Right () -> do
            previous <- readIORef identity
            if previous == IdentityReady
              then pure ()
              else do
                writeIORef identity IdentityReady
                modifyIORef' counts (\(created, trees) -> (created + 1, trees))
            pure (Right ())
      tree _ apply _ = do
        if apply then modifyIORef' counts (\(created, trees) -> (created, trees + 1)) else pure ()
        pure (Right ())
      backend = ProvisionBackend (pure (Right "11111111-1111-4111-8111-111111111111")) (const (Right <$> readIORef identity)) create tree (pure ())
  pure (ProvisionRuntime env allowAllActionAuthorizerForTests (pure (Right ())) backend, identity, counts)

enroll :: AppEnv -> WorkspaceBinding -> IO ()
enroll env binding = do
  now <- getCurrentTime
  let envelope = Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now)
  run env (Roots.enrollRootTx binding.request.rootId envelope) >>= (@?= Right Resources.Accepted)

pool :: IdentityRange
pool = IdentityRange 62000 62001

run :: AppEnv -> Transaction a -> IO a
run env action = right =<< runAppIO env (runTransaction action)

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
