{-# LANGUAGE DataKinds #-}

-- Registration/factual-receipt evidence only. No test here grants native Git
-- authority, proves HEAD publication or acknowledges an execution attempt.
module Shikigami.WorkspaceGitStoreSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as ClaimText
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Identity
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (NeedModel))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.StateRevision qualified as Generation
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.GitStore
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Provider (FileReceipt (..), ReceiptState (EditRefused))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace Git registrations"
    [ testCase "concurrent reservations and duplicate actuals retain the original identity and time" $ withGit fixture \env binding proposed -> do
        (a, b) <- concurrently (run env (reserveGitTx binding proposed)) (run env (reserveGitTx binding proposed))
        a @?= Right proposed
        b @?= a
        let duplicate = proposed & #createdAt .~ addUTCTime 1 proposed.createdAt & #attemptId .~ AttemptId "replacement" & #generation .~ (fixtureGeneration 2) & #claimOwner .~ (fixtureOwner "new-claim")
        run env (reserveGitTx binding duplicate) >>= (@?= Right proposed)
        let changed = proposed & #target .~ "other-target"
        run env (reserveGitTx binding (changed & #fingerprint .~ gitFingerprint binding changed)) >>= (@?= Left WorkspaceBindingConflict)
        run env (inspectRegisteredGitTx proposed.operation.operationId) >>= (@?= Just (binding, proposed)),
      testCase "publication consumes one transition and factual recovery survives owner freeze" $ withGit fixture \env binding proposed -> do
        _ <- right =<< run env (reserveGitTx binding proposed)
        prepared <- right =<< run env (prepareGitTx binding proposed candidate)
        run env (prepareGitTx binding proposed candidate) >>= (@?= Right prepared)
        (a, b) <- concurrently (run env (requestGitPublicationTx binding prepared)) (run env (requestGitPublicationTx binding prepared))
        outcomes <- mapM right [a, b]
        sort outcomes @?= [False, True]
        Just requested <- run env (inspectGitTx proposed.operation.operationId)
        unresolved <- right =<< run env (markGitUnresolvedTx requested)
        assertBlocked env binding
        run env (Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0)) >>= (@?= Right ())
        run env (requestGitPublicationTx binding prepared) >>= (@?= Left WorkspaceBindingConflict)
        applied <- right =<< run env (recordGitAppliedTx unresolved)
        applied.phase @?= GitApplied
        applied.attemptId @?= proposed.attemptId
        applied.generation @?= fixtureGeneration 1
        run env (recordGitAppliedTx requested) >>= (@?= Right applied),
      testCase "pre-publication refusal races the publication transition without inventing completion" $ withGit fixture \env binding proposed -> do
        _ <- right =<< run env (reserveGitTx binding proposed)
        prepared <- right =<< run env (prepareGitTx binding proposed candidate)
        (publish, refuse) <- concurrently (run env (requestGitPublicationTx binding prepared)) (run env (refuseGitBeforePublicationTx prepared))
        assertBool "only publication or refusal wins" (case (publish, refuse) of (Right True, Left WorkspaceBindingConflict) -> True; (Left WorkspaceBindingConflict, Right value) -> value.phase == GitRefused; _ -> False)
        Just retained <- run env (inspectGitTx proposed.operation.operationId)
        assertBool "no applied receipt was fabricated" (retained.phase `elem` [GitPublishRequested, GitRefused]),
      testCase "a prepared candidate alone cannot become applied or release the common barrier" $ withGit fixture \env binding proposed -> do
        _ <- right =<< run env (reserveGitTx binding proposed)
        prepared <- right =<< run env (prepareGitTx binding proposed candidate)
        run env (recordGitAppliedTx prepared) >>= (@?= Left WorkspaceBindingConflict)
        assertBlocked env binding
        run env (Store.reserveWorkspaceEffectTx binding binding.request.owner (fixtureRevision 0) (OperationId "file-operation") digest) >>= (@?= Left WorkspaceBindingConflict)
        refused <- right =<< run env (refuseGitBeforePublicationTx prepared)
        refused.phase @?= GitRefused
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (OperationId "successor")) >>= (@?= Right ())
        run env (requestGitPublicationTx binding prepared) >>= (@?= Left WorkspaceBindingConflict),
      testCase "historical file receipts stay typed and cannot be reinterpreted as Git records" $ withGit fixture \env binding proposed -> do
        let operation = proposed.operation.operationId
        run env (Store.reserveWorkspaceEffectTx binding binding.request.owner (fixtureRevision 0) operation digest) >>= (@?= Right Nothing)
        run env (reserveGitTx binding proposed) >>= (@?= Left WorkspaceBindingConflict)
        let receipt = FileReceipt operation (AttemptId "file-attempt") (fixtureGeneration 1) digest (workspaceBindingDigest binding) digest "dependency.txt" "device:parent" Nothing digest EditRefused
        run env (Store.recordWorkspaceReceiptTx binding receipt) >>= (@?= Right ())
        run env (Store.reserveWorkspaceEffectTx binding binding.request.owner (fixtureRevision 0) operation digest) >>= (@?= Right (Just receipt))
        run env (inspectGitTx operation) >>= (@?= Nothing)
        run env (reserveGitTx binding proposed) >>= (@?= Left WorkspaceBindingConflict),
      testCase "bounded factual scans include settled records and advance without relaunch authority" $ withGit fixture \env binding proposed -> do
        let keys = [Text.pack ("git-page-" <> show index) | index <- [1 .. 66 :: Int]]
        mapM_
          ( \key -> do
              let logical = proposed.operation & #operationId .~ OperationId key & #idempotencyKey .~ key
                  value = proposed & #operation .~ logical
                  entry = value & #fingerprint .~ gitFingerprint binding value
              retained <- right =<< run env (reserveGitTx binding entry)
              _ <- right =<< run env (refuseGitBeforePublicationTx retained)
              pure ()
          )
          keys
        first <- run env (inspectGitPageTx Nothing)
        first @?= take 64 (sort (map OperationId keys))
        second <- run env (inspectGitPageTx (Just (last first)))
        second @?= drop 64 (sort (map OperationId keys))
        run env (inspectGitPageTx (Just (last second))) >>= (@?= []),
      testCase "malformed records and changed candidate evidence refuse without replacing intent" $ withGit fixture \env binding proposed -> do
        run env (reserveGitTx binding (proposed & #generation .~ (fixtureGeneration 0))) >>= (@?= Left InvalidWorkspaceRequest)
        _ <- right =<< run env (reserveGitTx binding proposed)
        run env (prepareGitTx binding proposed (candidate & #paths .~ ["../escape"])) >>= (@?= Left WorkspaceBindingConflict)
        prepared <- right =<< run env (prepareGitTx binding proposed candidate)
        run env (prepareGitTx binding proposed (candidate & #result .~ Text.replicate 40 "d")) >>= (@?= Left WorkspaceBindingConflict)
        run env (recordGitAppliedTx (prepared & #generation .~ (fixtureGeneration 2))) >>= (@?= Left WorkspaceBindingConflict)
        Aeson.eitherDecode @GitRecord (Aeson.encode prepared) @?= Right prepared
    ]

withGit :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> GitRecord -> IO a) -> IO a
withGit fixture use = Fixture.withFixture fixture \env _ root repository -> do
  let owner = CompatibilityIdentity (fixtureAgentName "git-worker")
      request = WorkspaceRequest "git-run" Nothing (ExecutionRootId "git-root") owner owner (fixtureRevision 0)
  (binding, _) <- right =<< run env (Store.reserveWorkspaceTx root request repository)
  allocateWorkspace root binding Reserved >>= (@?= Right ())
  run env (Store.markWorkspaceReadyTx binding) >>= (@?= Right ())
  now <- getCurrentTime
  let logical = OperationContext (ExecutionId "git-execution") (OperationId "git-operation") "git-operation" digest digest
      record = GitRecord 1 logical (AttemptId "original-attempt") (fixtureOwner "original-claim") (fixtureGeneration 1) (workspaceBindingDigest binding) digest digest "device:parent" candidate.parent digest now (GitRouting logical.executionId owner digest NeedModel) GitReserved Nothing
  use env binding (record & #fingerprint .~ gitFingerprint binding record)

candidate :: GitCandidate
candidate = GitCandidate (Text.replicate 40 "a") (Text.replicate 40 "b") (Text.replicate 40 "c") ["dependency.txt"]

digest :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"

assertBlocked :: AppEnv -> WorkspaceBinding -> Assertion
assertBlocked env binding = run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (OperationId "successor")) >>= (@?= Left WorkspaceBindingConflict)

run :: AppEnv -> Transaction a -> IO a
run env action = runAppIO env (runTransaction action) >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureGeneration :: Integer -> Generation.StateRevision "execution-attempt"
fixtureGeneration value = either (error . show) id (Generation.parseRevision value)

fixtureOwner :: ClaimText.Text -> Claim.ClaimOwner
fixtureOwner value = either (error . show) id (Claim.parseClaimOwner value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
