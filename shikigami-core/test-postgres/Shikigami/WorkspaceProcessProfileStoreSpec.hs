{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceProcessProfileStoreSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude
import Shikigami.StateRevision (initialRevision)
import Shikigami.WorkerSession.Types (SessionAdmission (..))
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace process profile store"
    ( [ testCase "concurrent allocation and readiness retain the complete winner" $ withProfile fixture \env binding profile -> do
          let reserve = run env (reserveProcessProfileTx binding digest policy range)
          (a, b) <- concurrently reserve reserve
          a @?= Right (profile, ProfileReserved)
          b @?= a
          run env (readyProcessProfileTx binding profile) >>= (@?= Right ())
          reserve >>= (@?= Right (profile, ProfileReady))
          run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right (Just (profile, ProfileReady))),
        testCase "missing profiles remain absence" $ Fixture.withFixture fixture \env _ _ ->
          run env (inspectProcessProfileTx (WorkspaceRef "shikigami.workspace/1" "absent")) >>= (@?= Right Nothing),
        testCase "SQL failure remains a store failure and rolls back" $ withProfile fixture \env binding profile -> do
          failed <-
            runAppIO
              env
              ( runTransaction do
                  Tx.sql "ALTER TABLE shikigami.workspace_process_profiles RENAME TO unavailable_profile_fixture"
                  inspectProcessProfileTx binding.workspace
              )
          case failed of
            Left _ -> pure ()
            Right result -> assertFailure ("SQL failure was misclassified: " <> show result)
          run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right (Just (profile, ProfileReserved)))
      ]
        <> [ testCase ("corrupt " <> label <> " refuses, rolls back ignored refusal and recovers the same identity") $
               withProfile fixture \env binding profile -> do
                 -- The fixture persisted and read a complete valid profile first.
                 let operation = fixtureOperationId "profile-unresolved-effect"
                 run env (Workspaces.reserveWorkspaceEffectTx binding binding.request.owner binding.request.epoch operation digest) >>= (@?= Right Nothing)
                 replaceProfile env (invalid profile)
                 run env (inspectProcessProfileTx binding.workspace) >>= (@?= Left WorkspaceBindingConflict)
                 run env (reserveProcessProfileTx binding digest policy range) >>= (@?= Left WorkspaceBindingConflict)
                 run env (readyProcessProfileTx binding profile) >>= (@?= Left WorkspaceBindingConflict)
                 (frozen, refused, frozenInside) <- run env do
                   frozen <- Workspaces.freezeWorkspaceTx binding binding.request.owner binding.request.epoch
                   refused <- inspectProcessProfileTx binding.workspace
                   controlInside <- Workspaces.inspectWorkspaceControlTx binding
                   -- Deliberately return normally after ignoring the refusal.
                   pure (frozen, refused, fmap (fmap Workspaces.workspaceFrozen) controlInside)
                 frozen @?= Right ()
                 refused @?= Left WorkspaceBindingConflict
                 frozenInside @?= Right (Just True)
                 control <- right =<< run env (Workspaces.inspectWorkspaceControlTx binding)
                 fmap Workspaces.workspaceFrozen control @?= Just False
                 retained <- run env (Tx.statement () retainedFacts)
                 retained @?= (1, False, 1)
                 replaceProfile env (toJSON profile)
                 run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right (Just (profile, ProfileReserved)))
                 run env (reserveProcessProfileTx binding digest policy range) >>= (@?= Right (profile, ProfileReserved))
           | (label, invalid) <-
               [ ("JSON shape", const Aeson.Null),
                 ("Unix identity", \profile -> toJSON (profile & #groupId .~ (profile.userId + 1))),
                 ( "policy format",
                   \profile -> case toJSON profile of
                     Aeson.Object fields -> case toJSON profile.policy of
                       Aeson.Object policyFields -> Aeson.Object (KeyMap.insert "policy" (Aeson.Object (KeyMap.insert "format" (Aeson.Number 2) policyFields)) fields)
                       _ -> error "complete fixture policy must be an object"
                     _ -> error "complete fixture profile must be an object"
                 )
               ]
           ]
    )

withProfile :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ProcessProfile -> IO a) -> IO a
withProfile fixture callback = Fixture.withFixture fixture \env session _ -> do
  let base = Text.replicate 40 "a"
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy "mori://fixture/repository" "/approved/source" [base] base (processPolicyIdentity policy)])
  repository <- right (resolveRepository catalog "mori://fixture/repository" Nothing)
  root <- maybe (fail "missing root") pure session.context.executionRootId
  let request = WorkspaceRequest (WorkflowId "profile-run") Nothing root session.identity session.identity initialRevision
  (binding, _) <- right =<< run env (Workspaces.reserveWorkspaceTx "/private/owned-workspaces" request repository)
  run env (Workspaces.markWorkspaceReadyTx binding) >>= (@?= Right ())
  (profile, state) <- right =<< run env (reserveProcessProfileTx binding digest policy range)
  state @?= ProfileReserved
  assertBool "complete valid profile" (validProcessProfile profile)
  run env (inspectProcessProfileTx binding.workspace) >>= (@?= Right (Just (profile, ProfileReserved)))
  callback env binding profile

policy :: ProcessPolicy
policy = ProcessPolicy ProcessPolicyV1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") digest [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] ["src"]

range :: IdentityRange
range = IdentityRange 62000 62001

digest :: Text
digest = "sha256:" <> Text.replicate 64 "a"

replaceProfile :: AppEnv -> Aeson.Value -> IO ()
replaceProfile env value = run env (Tx.statement value (preparable "UPDATE shikigami.workspace_process_profiles SET profile=$1" (E.param (E.nonNullable E.jsonb)) D.noResult))

retainedFacts :: Statement () (Int64, Bool, Int64)
retainedFacts = preparable "SELECT (SELECT count(*) FROM shikigami.workspace_process_profiles),(SELECT bool_or(ready) FROM shikigami.workspace_process_profiles),(SELECT count(*) FROM shikigami.workspace_effects WHERE NOT settled)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.bool) <*> D.column (D.nonNullable D.int8)))

run :: AppEnv -> Tx.Transaction a -> IO a
run env action = right =<< runAppIO env (runTransaction action)

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
