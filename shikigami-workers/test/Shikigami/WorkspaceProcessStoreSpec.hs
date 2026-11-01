{-# LANGUAGE DataKinds #-}

-- Database registration evidence only: these fixtures do not claim a real
-- systemd invocation or establish a process fence.
module Shikigami.WorkspaceProcessStoreSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as ClaimText
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Identity
import Shikigami.Execution.Payload (parsePayloadDigest)
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (NeedModel), executionIdentity)
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId, fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.StateRevision qualified as Generation
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Collector
import Shikigami.Workspace.ContainedFile (ensurePrivateDirectory)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessStore
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory (createDirectory, removeFile)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace process registrations"
    [ testGroup
        "process metadata refusals"
        [ testCase "malformed process JSON retains its barrier" (malformedProcessMetadata fixture (Tx.sql "UPDATE shikigami.workspace_processes SET record='{}'::jsonb")),
          testCase "unsupported retained routing format retains its barrier" (malformedProcessMetadata fixture (Tx.sql "UPDATE shikigami.workspace_processes SET record=jsonb_set(record,'{routing,format}','2'::jsonb)")),
          testCase "malformed registered origin is an owning refusal" $ withProcess fixture \env binding proposed -> do
            run env (reserveProcessTx binding proposed) >>= (@?= Right proposed)
            run env (inspectRegisteredProcessTx proposed.operationId) >>= (@?= Right (Just (binding, proposed)))
            run env (Tx.sql "UPDATE shikigami.workspace_bindings SET binding=jsonb_build_object('id',binding->'id')")
            run env (inspectProcessTx proposed.operationId) >>= (@?= Right (Just proposed))
            run env (inspectRegisteredProcessTx proposed.operationId) >>= (@?= Left WorkspaceBindingConflict),
          testCase "routing format has exact closed numeric-one codecs" do
            Aeson.encode ProcessRoutingV1 @?= "1"
            Aeson.eitherDecode (Aeson.encode ProcessRoutingV1) @?= Right ProcessRoutingV1
            mapM_ (\value -> assertBool "unsupported format refused" (case Aeson.eitherDecode @ProcessRoutingFormat value of Left _ -> True; _ -> False)) ["0", "2", "-1", "1.5", "1e10000"]
        ],
      testCase "bounded factual scans advance past unresolved registrations and include unacknowledged settled facts" $ withProcess fixture \env binding proposed -> do
        let identifiers = [fixtureOperationId ("page-" <> Text.justifyRight 3 '0' (Text.pack (show index))) | index <- [1 .. 66 :: Int]]
        forM_ identifiers \operation -> do
          let candidate = proposed & #operationId .~ operation & #unit .~ processUnit operation proposed.fingerprint
          retained <- right =<< run env (reserveProcessTx binding candidate)
          run env (refuseReservedProcessTx retained) >>= (@?= Right ())
        -- A stuck registration sorts first. Recovery must not repeatedly
        -- select it instead of reaching the final two settled receipts.
        let stuckId = fixtureOperationId "000-unresolved"
            stuck = proposed & #operationId .~ stuckId & #unit .~ processUnit stuckId proposed.fingerprint
        _ <- right =<< run env (reserveProcessTx binding stuck)
        run env (requestProcessLaunchTx binding stuck boot) >>= (@?= Right True)
        run env (markProcessUnresolvedTx stuck) >>= (@?= Right ())
        first <- run env (inspectProcessPageTx Nothing)
        first @?= stuckId : take 63 identifiers
        second <- run env (inspectProcessPageTx (Just (last first)))
        second @?= drop 63 identifiers
        run env (inspectProcessPageTx (Just (last second))) >>= (@?= [])
        run env (inspectProcessPageTx Nothing) >>= (@?= first),
      testCase "historical registrations keep their JSON fields and omit absent receipt routing" $ withProcess fixture \_ _ proposed -> do
        case Aeson.toJSON proposed of
          Aeson.Object fields -> do
            assertBool "new routing does not appear on old records" (not (KeyMap.member "routing" fields))
            KeyMap.lookup "bootId" fields @?= Just Aeson.Null
            KeyMap.lookup "receipt" fields @?= Just Aeson.Null
          _ -> assertFailure "registration JSON must be an object"
        Aeson.eitherDecode @ProcessRecord (Aeson.encode proposed) @?= Right proposed,
      testCase "racing reservations and lost launch acknowledgement converge without a second launch grant" $ withProcess fixture \env binding proposed -> do
        (one, two) <- concurrently (run env (reserveProcessTx binding proposed)) (run env (reserveProcessTx binding proposed))
        one @?= Right proposed
        two @?= Right proposed
        let changed = proposed & #command . #arguments .~ ["different"]
        run env (reserveProcessTx binding changed) >>= (@?= Left WorkspaceBindingConflict)
        let otherId = fixtureOperationId "other-operation"
            other = proposed & #operationId .~ otherId & #unit .~ processUnit otherId proposed.fingerprint
        run env (reserveProcessTx binding other) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "read")) >>= (@?= Left WorkspaceBindingConflict)
        (a, b) <- concurrently (run env (requestProcessLaunchTx binding proposed boot)) (run env (requestProcessLaunchTx binding proposed boot))
        granted <- traverse right [a, b]
        sort granted @?= [False, True]
        let replacement = proposed & #attemptId .~ fixtureAttemptId "replacement" & #generation .~ (fixtureGeneration 2) & #deadline .~ addUTCTime 3600 proposed.deadline
        retained <- right =<< run env (reserveProcessTx binding replacement)
        retained.attemptId @?= proposed.attemptId
        retained.deadline @?= proposed.deadline
        run env (requestProcessLaunchTx binding replacement boot) >>= (@?= Right False),
      testCase "a proven pre-launch refusal races the launch grant without inventing a process receipt" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        (launch, refused) <- concurrently (run env (requestProcessLaunchTx binding proposed boot)) (run env (refuseReservedProcessTx proposed))
        Just actual <- right =<< run env (inspectProcessTx proposed.operationId)
        actual.receipt @?= Nothing
        case actual.phase of
          ProcessRefused -> do
            launch @?= Left WorkspaceBindingConflict
            refused @?= Right ()
            run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Right ())
          ProcessLaunchRequested -> do
            launch @?= Right True
            refused @?= Left WorkspaceBindingConflict
            run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Left WorkspaceBindingConflict)
          other -> assertFailure ("unexpected launch/refusal race: " <> show other),
      testCase "missing launch evidence stays unresolved and blocks file reuse until a matching receipt" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right True)
        run env (markProcessUnresolvedTx proposed) >>= (@?= Right ())
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right False)
        run env (observeProcessInvocationTx proposed otherBoot invocation) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Left WorkspaceBindingConflict)
        run env (observeProcessInvocationTx proposed boot invocation) >>= (@?= Right ())
        run env (observeProcessInvocationTx proposed boot otherBoot) >>= (@?= Left WorkspaceBindingConflict)
        run env (recordProcessReceiptTx (receiptFor proposed)) >>= (@?= Right ())
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Right ()),
      testCase "factual receipts settle after freeze but cannot replace invocation, output or descendant evidence" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right True)
        run env (observeProcessInvocationTx proposed boot invocation) >>= (@?= Right ())
        run env (Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0)) >>= (@?= Right ())
        let receipt = receiptFor proposed
        mapM_
          (\invalid -> run env (recordProcessReceiptTx invalid) >>= (@?= Left WorkspaceBindingConflict))
          [ receipt & #bootId .~ otherBoot,
            receipt & #invocationId .~ otherBoot,
            receipt & #generation .~ (fixtureGeneration 2),
            receipt & #descendantsEmpty .~ False,
            receipt & #outputComplete .~ False,
            receipt & #exitCode .~ Nothing,
            receipt & #stdout . #bytes .~ 100000
          ]
        run env (recordProcessReceiptTx receipt) >>= (@?= Right ())
        run env (recordProcessReceiptTx receipt) >>= (@?= Right ())
        run env (recordProcessReceiptTx (receipt & #exitCode .~ Just 1)) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOwnerTx binding binding.request.owner (fixtureRevision 0)) >>= (@?= Left WorkspaceBindingConflict)
        Just retained <- right =<< run env (inspectProcessTx proposed.operationId)
        retained.phase @?= ProcessSettled,
      testCase "private collector completion reconciles the original attempt after freeze and acknowledgement loss" $ withProcess fixture \env binding proposed -> do
        record <- launchRecord env binding proposed
        directory <- collectorDirectory binding
        writeCollector directory record []
        run env (Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0)) >>= (@?= Right ())
        Just receipt <- right =<< reconcileCollector env directory record
        receipt.attemptId @?= proposed.attemptId
        receipt.generation @?= proposed.generation
        receipt.stdout.bytes @?= 7
        receipt.stdout.truncated @?= True
        reconcileCollector env directory record >>= (@?= Right (Just receipt))
        Just actual <- right =<< run env (inspectProcessTx proposed.operationId)
        actual.phase @?= ProcessSettled
        actual.receipt @?= Just receipt,
      testCase "collector evidence rejects mismatched identities, incomplete settlement and inconsistent output" $ withProcess fixture \env binding proposed -> do
        record <- launchRecord env binding proposed
        directory <- collectorDirectory binding
        mapM_
          ( \changed -> do
              writeCollector directory record changed
              readCollectorReceipt directory record >>= (@?= Left CollectorEvidenceConflict)
              Just actual <- right =<< run env (inspectProcessTx proposed.operationId)
              actual.phase @?= ProcessLaunchRequested
          )
          [ ["bootId" .= otherBoot],
            ["invocationId" .= ("invalid" :: Text.Text)],
            ["unit" .= ("unrelated.service" :: Text.Text)],
            ["fingerprint" .= ("sha256:" <> Text.replicate 64 "b")],
            ["stdoutBytes" .= (6 :: Int)],
            ["descendantsEmpty" .= False],
            ["outputComplete" .= False]
          ]
        writeCollector directory record []
        Bytes.writeFile (directory </> "stdout") (Bytes.replicate 1025 120)
        readCollectorReceipt directory record >>= (@?= Left CollectorUnavailable)
        writeCollector directory record []
        removeFile (directory </> "stderr")
        readCollectorReceipt directory record >>= (@?= Left CollectorUnavailable),
      testCase "observed invocation alone cannot settle and conflicting collector facts keep the barrier closed" $ withProcess fixture \env binding proposed -> do
        record <- launchRecord env binding proposed
        directory <- collectorDirectory binding
        Lazy.writeFile (directory </> "observed.json") (Aeson.encode (Aeson.object ["bootId" .= boot, "invocationId" .= invocation]))
        reconcileCollector env directory record >>= (@?= Right Nothing)
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Left WorkspaceBindingConflict)
        writeCollector directory record ["invocationId" .= otherBoot]
        reconcileCollector env directory record >>= (@?= Left CollectorEvidenceConflict)
        run env (markProcessUnresolvedTx record) >>= (@?= Right ())
        writeCollector directory record []
        Just _ <- right =<< reconcileCollector env directory record
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Right ()),
      testCase "timeout settlement preserves unavailable status and cannot be interpreted as successful validation" $ withProcess fixture \env binding proposed -> do
        record <- launchRecord env binding proposed
        directory <- collectorDirectory binding
        let unknownStatus = ["exitCode" .= Aeson.Null, "termination" .= ProcessTimedOut]
        writeCollector directory record unknownStatus
        readCollectorReceipt directory record >>= (@?= Left CollectorEvidenceConflict)
        writeCollector directory record (["version" .= (2 :: Int), "termination" .= ProcessExited, "exitCode" .= Aeson.Null])
        readCollectorReceipt directory record >>= (@?= Left CollectorEvidenceConflict)
        writeCollector directory record (["version" .= (2 :: Int)] <> unknownStatus)
        Just receipt <- right =<< reconcileCollector env directory record
        receipt.exitCode @?= Nothing
        receipt.termination @?= ProcessTimedOut
        assertBool "missing status is never validation success" (not (processSucceeded receipt))
        assertBool "timeout remains failure even with a zero exit status" (not (processSucceeded (receipt & #exitCode .~ Just 0)))
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "later")) >>= (@?= Right ())
    ]

-- These JSON fixtures exercise receipt validation and database ownership; only
-- probe-collector-apple.sh establishes facts from actual Linux services.
launchRecord :: AppEnv -> WorkspaceBinding -> ProcessRecord -> IO ProcessRecord
launchRecord env binding proposed = do
  _ <- right =<< run env (reserveProcessTx binding proposed)
  run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right True)
  pure (proposed & #bootId .~ Just boot & #phase .~ ProcessLaunchRequested)

collectorDirectory :: WorkspaceBinding -> IO FilePath
collectorDirectory binding = do
  let directory = workspaceMetadata binding.storageRoot binding </> "collector-test"
  createDirectory directory
  ensurePrivateDirectory directory >>= (@?= Right ())
  pure directory

writeCollector :: FilePath -> ProcessRecord -> [Pair] -> IO ()
writeCollector directory record changed = do
  Bytes.writeFile (directory </> "stdout") "bounded"
  Bytes.writeFile (directory </> "stderr") ""
  let base =
        Aeson.object
          [ "version" .= (1 :: Int),
            "unit" .= record.unit,
            "fingerprint" .= record.fingerprint,
            "bootId" .= boot,
            "invocationId" .= invocation,
            "exitCode" .= (0 :: Int),
            "termination" .= ProcessExited,
            "stdoutBytes" .= (7 :: Int),
            "stderrBytes" .= (0 :: Int),
            "stdoutTruncated" .= True,
            "stderrTruncated" .= False,
            "descendantsEmpty" .= True,
            "outputComplete" .= True
          ]
      overrides = Aeson.object changed
      fact = case (overrides, base) of (Aeson.Object a, Aeson.Object b) -> Aeson.Object (a <> b); _ -> base
  Lazy.writeFile (directory </> "complete.json") (Aeson.encode fact)

withProcess :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ProcessRecord -> IO a) -> IO a
withProcess fixture use = Fixture.withFixture fixture \env _ root repository -> do
  let owner = CompatibilityIdentity (fixtureAgentName "process-worker")
      request = WorkspaceRequest "process-run" Nothing (fixtureRootId "process-root") owner owner (fixtureRevision 0)
  (binding, _) <- right =<< run env (Store.reserveWorkspaceTx root request repository)
  allocateWorkspace root binding Reserved >>= (@?= Right ())
  run env (Store.markWorkspaceReadyTx binding) >>= (@?= Right ())
  now <- getCurrentTime
  let command = ProcessCommand "validate" digest "/bin/validate" [] "" (Map.fromList [("HOME", "/scratch"), ("TMPDIR", "/scratch")]) 30 1024
      operation = fixtureOperationId "process-operation"
      logical = OperationContext (executionIdentity "process-execution") operation (fixtureOperationId "process-operation") (ExecutionValue.executionDigest "input-fingerprint") (ExecutionValue.executionDigest "scope")
      fingerprint = processFingerprint binding digest logical command
      record = ProcessRecord operation (fixtureAttemptId "original-attempt") (fixtureOwner "original-claim") (fixtureGeneration 1) (workspaceBindingDigest binding) digest fingerprint command (addUTCTime 30 now) (processUnit operation fingerprint) Nothing Nothing ProcessReserved Nothing Nothing
  use env binding record

receiptFor :: ProcessRecord -> ProcessReceipt
receiptFor record = ProcessReceipt record.operationId record.attemptId record.generation record.fingerprint record.bindingDigest record.unit boot invocation (Just 0) ProcessExited (CapturedOutput "stdout" digest 0 False) (CapturedOutput "stderr" digest 0 False) True True

digest :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"

boot, otherBoot, invocation :: Text.Text
boot = "11111111-1111-4111-8111-111111111111"
otherBoot = "22222222-2222-4222-8222-222222222222"
invocation = "33333333-3333-4333-8333-333333333333"

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

malformedProcessMetadata :: DatabaseFixture -> Transaction () -> IO ()
malformedProcessMetadata fixture corrupt = withProcess fixture \env binding original -> do
  let inputDigest = either (error . show) id (parsePayloadDigest original.fingerprint)
      routing = ProcessRouting ProcessRoutingV1 (executionIdentity "process-routing") binding.request.owner inputDigest NeedModel
      proposed = original & #routing .~ Just routing
  run env (reserveProcessTx binding proposed) >>= (@?= Right proposed)
  run env (inspectProcessTx proposed.operationId) >>= (@?= Right (Just proposed))
  run env (inspectRegisteredProcessTx proposed.operationId) >>= (@?= Right (Just (binding, proposed)))
  run env corrupt
  run env (inspectProcessTx proposed.operationId) >>= (@?= Left WorkspaceBindingConflict)
  run env (inspectRegisteredProcessTx proposed.operationId) >>= (@?= Left WorkspaceBindingConflict)
  run env (reserveProcessTx binding proposed) >>= (@?= Left WorkspaceBindingConflict)
  run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Left WorkspaceBindingConflict)
  run env (observeProcessInvocationTx proposed boot invocation) >>= (@?= Left WorkspaceBindingConflict)
  run env (recordProcessReceiptTx (receiptFor proposed)) >>= (@?= Left WorkspaceBindingConflict)
  run env (refuseReservedProcessTx proposed) >>= (@?= Left WorkspaceBindingConflict)
  during <- run env do
    frozen <- Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0)
    control <- Store.inspectWorkspaceControlTx binding
    inspected <- inspectProcessTx proposed.operationId
    pure (frozen, fmap (fmap Store.workspaceFrozen) control, inspected)
  during @?= (Right (), Right (Just True), Left WorkspaceBindingConflict)
  run env (Store.checkWorkspaceOwnerTx binding binding.request.owner (fixtureRevision 0)) >>= (@?= Right ())
  run env (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (fixtureOperationId "successor")) >>= (@?= Left WorkspaceBindingConflict)
