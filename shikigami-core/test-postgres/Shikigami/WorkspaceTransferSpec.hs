{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceTransferSpec (tests) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent.Async (concurrently)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Text qualified as AssignmentText
import Data.Text qualified as Text
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Execution.AssignmentKey (AssignmentKey, parseAssignmentKey)
import Shikigami.Execution.Identity (AttemptId, OperationId, operationIdText)
import Shikigami.Execution.SelectionRuntime qualified as Selection
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.StateRevision (StateRevision, advanceRevision, parseRevision)
import Shikigami.StateRevision qualified as Generation
import Shikigami.WorkerSession.Checkpoint (ObjectiveVersion (..))
import Shikigami.WorkerSession.Input (InstructionText, parseInstructionText)
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types hiding (assignmentIdFor)
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.CleanupStore
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.TransferStore
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace transfer store"
    [ testCase "workspace listing retains bounded root-scoped keyset pages" (workspacePages fixture),
      testCase "unreadable child attribution cannot become standalone absence" (corruptChildMapping fixture),
      testCase "binding and control corruption refuse and roll back ignored reads" (corruptWorkspaceReads fixture),
      testCase "retained transfer corruption cannot authorize another freeze or fence" (corruptTransferReads fixture),
      testCase "cleanup absence and SQL failure remain distinct" $ withWorkspace fixture \env _ _ binding _ -> do
        run env (runTransaction (inspectCleanupTx binding)) >>= (@?= Right Nothing)
        run env (runTransaction (listWorkspacesTx (workspaceLocatorPath binding.storageRoot) Nothing)) >>= (@?= Right [binding])
        failed <-
          runAppIO
            env
            ( runTransaction do
                Tx.sql "ALTER TABLE shikigami.workspace_cleanup RENAME TO unavailable_cleanup_fixture"
                inspectCleanupTx binding
            )
        case failed of Left _ -> pure (); Right _ -> assertFailure "SQL failure became a domain result"
        run env (runTransaction (inspectCleanupTx binding)) >>= (@?= Right Nothing),
      testCase "cleanup listing refuses a corrupt member beside a valid allocation and rolls back" $ withWorkspace fixture \env _ _ binding _ -> do
        catalog <- right (mkWorkspaceCatalog [RepositoryPolicy binding.repository binding.source [binding.base] binding.base binding.policyRevision])
        repository <- right (resolveRepository catalog binding.repository Nothing)
        (second, _) <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx (workspaceLocatorPath binding.storageRoot) (binding.request & #runId .~ WorkflowId "cleanup-list-second" & #assignment .~ Nothing) repository))
        listed <- right =<< run env (runTransaction (listWorkspacesTx (workspaceLocatorPath binding.storageRoot) Nothing))
        length listed @?= 2
        let replace value = run env (runTransaction (Tx.statement (workspaceCoordinateText second.workspace.resource, value) (preparable "UPDATE shikigami.workspace_bindings SET binding=$2 WHERE resource=$1" (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.jsonb))) D.noResult)))
        forM_ ["repository", "storageRoot"] \field -> do
          -- Both an ordinary required field and the old JSON selector must
          -- remain visible to the owning whole-page decoder.
          replace (case Aeson.toJSON second of Aeson.Object fields -> Aeson.Object (KeyMap.insert field Aeson.Null fields); _ -> error "complete fixture binding must be an object")
          (frozen, refused) <-
            run
              env
              ( runTransaction do
                  frozen <- Workspaces.freezeWorkspaceTx binding binding.request.owner binding.request.epoch
                  refused <- listWorkspacesTx (workspaceLocatorPath binding.storageRoot) Nothing
                  pure (frozen, refused)
              )
          frozen @?= Right ()
          refused @?= Left WorkspaceBindingConflict
          control <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
          fmap Workspaces.workspaceFrozen control @?= Just False
          replace (Aeson.toJSON second)
          recovered <- right =<< run env (runTransaction (listWorkspacesTx (workspaceLocatorPath binding.storageRoot) Nothing))
          length recovered @?= 2,
      testCase "only retained child mappings supply session assignment coordinates" $ withWorkspace fixture \env _ _ binding original -> do
        current <- right =<< run env (runTransaction (lookupSessionChildTx binding.request.runId))
        case current of
          Just child -> do
            Just (child.session, child.assignment) @?= binding.request.assignment
            child.owner @?= original.owner
            child.epoch @?= (fixtureRevision 0)
          Nothing -> assertFailure "missing actual session child"
        run env (runTransaction (lookupSessionChildTx (WorkflowId "payload-selected-session"))) >>= (@?= Right Nothing),
      testCase "freeze deduplicates concurrent delivery and conflicting intents cannot change ownership" $ withWorkspace fixture \env session access binding _ -> do
        intent <- request env session access binding
        let begin = run env (runTransaction (beginTransferTx binding intent))
        (a, b) <- concurrently begin begin
        a @?= Right Nothing
        b @?= Right Nothing
        run env (runTransaction (beginTransferTx binding (intent & #newOwner .~ compatibilityIdentity (fixtureAgentName "intruder")))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding intent.oldOwner (fixtureRevision 0))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding intent.newOwner (fixtureRevision 1))) >>= (@?= Left WorkspaceBindingConflict)
        proof <- right =<< run env (runTransaction (retainFenceTx binding intent))
        assertBool "proof binds the entire retained transfer" (matchesFence intent proof)
        begin >>= (@?= Right (Just proof))
        run env (runTransaction (retainFenceTx binding intent)) >>= (@?= Right proof),
      testCase "an invented unretained transfer cannot freeze the allocation" $ withWorkspace fixture \env session _ binding _ -> do
        version <- Fixture.checkpointVersion session
        let intent = TransferIntent V1 (sessionIdFor session) session.objective session.context.identity (fixtureOperationId "invented") version session.identity successor (fixtureAgentName "successor") (fixtureRevision 0) (fixtureRevision 1) binding.request.rootId binding.workspace
        run env (runTransaction (beginTransferTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding session.identity (fixtureRevision 0))) >>= (@?= Right ()),
      testCase "prepared file effects preserve uncertainty until factual settlement after freeze" $ withWorkspace fixture \env session access binding original -> do
        let operation = fixtureOperationId "pending-file"
            digest = "sha256:" <> Text.replicate 64 "a"
            prepared = FileReceipt operation (fixtureAttemptId "original-actual") (fixtureGeneration 1) (workspaceCoordinate digest) (workspaceBindingDigest binding) (bundleDigest original.instructions) (workspaceCoordinate ("dependency.txt")) (workspaceCoordinate ("1:2")) Nothing (workspaceCoordinate digest) EditPrepared
        _ <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceEffectTx binding session.identity (fixtureRevision 0) operation (workspaceCoordinate digest)))
        run env (runTransaction (Workspaces.recordWorkspaceReceiptTx binding prepared)) >>= (@?= Right ())
        intent <- request env session access binding
        _ <- right =<< run env (runTransaction (beginTransferTx binding intent))
        run env (runTransaction (retainFenceTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (pendingWorkspaceOperationsTx binding)) >>= (@?= Right [(operation, "file")])
        -- A malformed retained key must keep the frozen allocation unresolved;
        -- it cannot disappear from the pending set or become a transport error.
        renamePendingKey env (operationIdText operation) ""
        run env (runTransaction (pendingWorkspaceOperationsTx binding)) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (retainFenceTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
        renamePendingKey env "" (operationIdText operation)
        run env (runTransaction (Workspaces.recordWorkspaceReceiptTx binding (prepared & #state .~ EditRefused))) >>= (@?= Right ())
        proof <- right =<< run env (runTransaction (retainFenceTx binding intent))
        assertBool "settled proof" (matchesFence intent proof),
      testCase "successor requires the established session and a retained fence before conditional admission" $ withWorkspace fixture \env session access binding original -> do
        intent <- request env session access binding
        _ <- right =<< run env (runTransaction (beginTransferTx binding intent))
        proof <- right =<< run env (runTransaction (retainFenceTx binding intent))
        -- These are the existing consumer contracts. The synthetic objective
        -- receipt tests the workspace store only; it is not IR-13 qualification.
        current <- sessionState env session
        _ <- right =<< run env (Sessions.retainTransferFence access current.revision (fixtureRevision 0) (fixtureOperationId "retain-fence") intent.operationId (FencedAndSettled proof))
        Just (_, first) <- pure binding.request.assignment
        pending <- sessionState env session
        _ <- right =<< run env (Sessions.recordResult access pending.revision (fixtureRevision 0) (fixtureOperationId "finish-original") (AssignmentResult V1 first AssignmentSucceeded Nothing Aeson.Null []))
        ready <- sessionState env session
        let checkpoint = OwnershipReceipt V1 intent.objective intent.operationId (ownershipFingerprint intent proof) (advanceRevision intent.expected.revision)
        _ <- right =<< run env (Sessions.establishOwner access ready.revision (fixtureRevision 0) (fixtureOperationId "establish") intent.operationId proof checkpoint)
        established <- sessionState env session
        (_, message) <- right =<< run env (Sessions.acceptMessage access established.revision (fixtureRevision 1) (fixtureOperationId "successor-message") instruction)
        (_, started) <- right =<< run env (Sessions.startAssignment access (advanceRevision established.revision) (fixtureRevision 1) (fixtureOperationId "successor-start") message.assignmentId)
        runId <- maybe (fail "missing successor child") pure started.childWorkflowId
        let admission = original & #runId .~ runId & #assignmentId .~ Selection.assignmentIdFor runId.unWorkflowId & #owner .~ successor & #epoch .~ (fixtureRevision 1)
        Right (Just child) <- run env (runTransaction (lookupSessionChildTx runId))
        run env (runTransaction (successorWorkspaceTx child)) >>= (@?= Right binding)
        run env (runTransaction (checkWorkspaceAdmissionTx binding admission (fixtureOperationId "before-admission"))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (admitSuccessorTx binding admission)) >>= (@?= Right ())
        run env (runTransaction (admitSuccessorTx binding admission)) >>= (@?= Right ())
        run env (runTransaction (checkWorkspaceAdmissionTx binding admission (fixtureOperationId "successor-effect"))) >>= (@?= Right ())
        run env (runTransaction (checkWorkspaceAdmissionTx binding original (fixtureOperationId "late-old-effect"))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (lookupSessionChildTx binding.request.runId)) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (admitSuccessorTx binding (admission & #assignmentId .~ (fixtureAssignment "payload-assignment")))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (admitSuccessorTx binding (admission & #filePolicy .~ Just supervisedFilePolicy))) >>= (@?= Left WorkspaceBindingConflict)
        run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Right (Just (binding, Ready)))
        effective <- right =<< run env (runTransaction (currentWorkspaceRequestTx binding))
        fmap (.runId) effective @?= Just runId
        fmap (.assignment) effective @?= Just (Just (sessionIdFor session, message.assignmentId))
        fmap (.owner) effective @?= Just successor
        fmap (.epoch) effective @?= Just (fixtureRevision 1)
        let replaceAdmission value = run env (runTransaction (Tx.statement value (preparable "UPDATE shikigami.workspace_successor_admissions SET admission=$1" (E.param (E.nonNullable E.jsonb)) D.noResult)))
        mapM_
          ( \value -> do
              replaceAdmission value
              run env (runTransaction (currentWorkspaceRequestTx binding)) >>= (@?= Left WorkspaceBindingConflict)
              run env (runTransaction (cleanupEligibleTx binding)) >>= (@?= Left WorkspaceBindingConflict)
              run env (runTransaction (admitSuccessorTx binding admission)) >>= (@?= Left WorkspaceBindingConflict)
              refused <-
                run
                  env
                  ( runTransaction do
                      Tx.sql "UPDATE shikigami.workspace_controls SET frozen=true"
                      currentWorkspaceRequestTx binding
                  )
              refused @?= Left WorkspaceBindingConflict
              replaceAdmission (Aeson.toJSON admission)
              current <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
              fmap Workspaces.workspaceFrozen current @?= Just False
              run env (runTransaction (admitSuccessorTx binding admission)) >>= (@?= Right ())
          )
          [Aeson.Null, Aeson.toJSON (admission & #runId .~ WorkflowId "wrong-retained-run")]
    ]

successor :: AgentIdentity
successor = compatibilityIdentity (fixtureAgentName "successor")

instruction :: Instruction
instruction = Instruction V1 FollowUp (fixtureInstruction "bounded fixture assignment") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing

withWorkspace :: DatabaseFixture -> (AppEnv -> SessionAdmission -> Sessions.SessionAccess -> WorkspaceBinding -> WorkspaceAdmission -> IO a) -> IO a
withWorkspace fixture callback = Fixture.withConfiguredFixture fixture (\admission -> admission & #delegator . #delegates .~ map fixtureAgentName ["worker", "successor"]) \env session access -> do
  (_, message) <- right =<< run env (Sessions.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "initial-message") instruction)
  (_, started) <- right =<< run env (Sessions.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "initial-start") message.assignmentId)
  runId <- maybe (fail "missing original child") pure started.childWorkflowId
  root <- maybe (fail "missing root") pure session.context.executionRootId
  let base = workspaceCoordinate (Text.replicate 40 "a")
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy (repositoryId "mori://fixture/repository") (workspaceLocator "/approved/source") [base] base (workspaceCoordinate "policy-1")])
  repository <- right (resolveRepository catalog (repositoryId "mori://fixture/repository") Nothing)
  (binding, _) <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx "/private/owned-workspaces" (WorkspaceRequest runId (Just (sessionIdFor session, started.assignmentId)) root session.identity session.identity (fixtureRevision 0)) repository))
  run env (runTransaction (Workspaces.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  instructions <- right (mkInstructionBundle 65536 binding.repository binding.base [(workspaceCoordinate "AGENTS.md", "validate before committing")])
  let original = WorkspaceAdmission binding.workspace (workspaceBindingDigest binding) runId (Selection.assignmentIdFor runId.unWorkflowId) root session.identity (fixtureRevision 0) instructions (Just transferableFilePolicy)
  callback env session access binding original

request :: AppEnv -> SessionAdmission -> Sessions.SessionAccess -> WorkspaceBinding -> IO TransferIntent
request env session access binding = do
  current <- sessionState env session
  version <- Fixture.checkpointVersion session
  snd <$> (right =<< run env (Sessions.requestTransfer access current.revision (fixtureRevision 0) (fixtureOperationId "transfer") version binding.workspace (fixtureAgentName "successor") successor))

sessionState :: AppEnv -> SessionAdmission -> IO SessionState
sessionState env session = do
  Just (state, _) <- right =<< run env (Sessions.inspectSession (sessionIdFor session))
  pure state

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureAssignment :: AssignmentText.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey

fixtureGeneration :: Integer -> Generation.StateRevision "execution-attempt"
fixtureGeneration value = either (error . show) id (Generation.parseRevision value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

renamePendingKey :: AppEnv -> Text.Text -> Text.Text -> IO ()
renamePendingKey env original replacement = run env (runTransaction (Tx.statement (original, replacement) statement))
  where
    statement = preparable "UPDATE shikigami.workspace_effects SET operation_id=$2 WHERE operation_id=$1" (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text))) D.noResult

corruptWorkspaceReads :: DatabaseFixture -> IO ()
corruptWorkspaceReads fixture = withWorkspace fixture \env _ _ binding _ -> do
  let sql text = run env (runTransaction (Tx.sql text))
      replace statement value = run env (runTransaction (Tx.statement value (preparable statement (E.param (E.nonNullable E.jsonb)) D.noResult)))
  run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Right (Just (binding, Ready)))
  sql "ALTER TABLE shikigami.workspace_bindings DROP CONSTRAINT workspace_entity_identity_matches_binding"
  mapM_
    ( \value -> do
        replace "UPDATE shikigami.workspace_bindings SET binding=$1" value
        run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Left WorkspaceBindingConflict)
        refused <-
          run
            env
            ( runTransaction do
                Tx.sql "UPDATE shikigami.workspace_controls SET frozen=true"
                result <- Workspaces.inspectWorkspaceTx binding.workspace
                pure result
            )
        refused @?= Left WorkspaceBindingConflict
        replace "UPDATE shikigami.workspace_bindings SET binding=$1" (Aeson.toJSON binding)
        control <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
        fmap Workspaces.workspaceFrozen control @?= Just False
        run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Right (Just (binding, Ready)))
    )
    [Aeson.Null, Aeson.toJSON (binding & #workspace . #resource .~ (workspaceCoordinate "wrong-address"))]
  replace "UPDATE shikigami.workspace_controls SET owner=$1" Aeson.Null
  run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding)) >>= (@?= Left WorkspaceBindingConflict)
  ignored <-
    run
      env
      ( runTransaction do
          Tx.sql "UPDATE shikigami.workspace_controls SET frozen=true"
          Workspaces.inspectWorkspaceControlTx binding
      )
  ignored @?= Left WorkspaceBindingConflict
  replace "UPDATE shikigami.workspace_controls SET owner=$1" (Aeson.toJSON binding.request.owner)
  restored <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
  fmap Workspaces.workspaceFrozen restored @?= Just False
  -- A genuine SQL error still escapes through the store boundary and rolls back
  -- the task-local table rename, independently of the domain refusal path.
  unavailable <-
    runAppIO
      env
      ( runTransaction do
          Tx.sql "ALTER TABLE shikigami.workspace_bindings RENAME TO workspace_bindings_unavailable"
          Workspaces.inspectWorkspaceTx binding.workspace
      )
  case unavailable of
    Left _ -> pure ()
    Right _ -> assertFailure "SQL failure became a domain value"
  run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Right (Just (binding, Ready)))

corruptTransferReads :: DatabaseFixture -> IO ()
corruptTransferReads fixture = withWorkspace fixture \env session access binding _ -> do
  intent <- request env session access binding
  run env (runTransaction (inspectTransferTx binding intent.oldEpoch)) >>= (@?= Right Nothing)
  run env (runTransaction (beginTransferTx binding intent)) >>= (@?= Right Nothing)
  run env (runTransaction (inspectTransferTx binding intent.oldEpoch)) >>= (@?= Right (Just (intent, Nothing)))
  let replace column value = run env (runTransaction (Tx.statement value (preparable ("UPDATE shikigami.workspace_transfers SET " <> column <> "=$1") (E.param (E.nonNullable E.jsonb)) D.noResult)))
  replace "intent" Aeson.Null
  run env (runTransaction (inspectTransferTx binding intent.oldEpoch)) >>= (@?= Left WorkspaceBindingConflict)
  run env (runTransaction (beginTransferTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
  run env (runTransaction (retainFenceTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
  ignored <-
    run
      env
      ( runTransaction do
          Tx.sql "UPDATE shikigami.workspace_controls SET frozen=false"
          inspectTransferTx binding intent.oldEpoch
      )
  ignored @?= Left WorkspaceBindingConflict
  control <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
  fmap Workspaces.workspaceFrozen control @?= Just True
  replace "intent" (Aeson.toJSON intent)
  proof <- right =<< run env (runTransaction (retainFenceTx binding intent))
  replace "proof" Aeson.Null
  run env (runTransaction (inspectTransferTx binding intent.oldEpoch)) >>= (@?= Left WorkspaceBindingConflict)
  run env (runTransaction (beginTransferTx binding intent)) >>= (@?= Left WorkspaceBindingConflict)
  replace "proof" (Aeson.toJSON proof)
  run env (runTransaction (inspectTransferTx binding intent.oldEpoch)) >>= (@?= Right (Just (intent, Just proof)))
  run env (runTransaction (retainFenceTx binding intent)) >>= (@?= Right proof)

corruptChildMapping :: DatabaseFixture -> IO ()
corruptChildMapping fixture = withWorkspace fixture \env _ _ binding _ -> do
  Right (Just original) <- run env (runTransaction (lookupSessionChildTx binding.request.runId))
  run env (runTransaction (lookupSessionChildTx (WorkflowId "unrelated-standalone-run"))) >>= (@?= Right Nothing)
  retained <- run env (runTransaction (Tx.statement () (preparable "SELECT state FROM shikigami.worker_session_messages" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb))))))
  let replace value = run env (runTransaction (Tx.statement value (preparable "UPDATE shikigami.worker_session_messages SET state=$1" (E.param (E.nonNullable E.jsonb)) D.noResult)))
      lostChild = case retained of Aeson.Object fields -> Aeson.Object (KeyMap.delete "childWorkflowId" fields); _ -> error "complete message metadata was not an object"
  replace lostChild
  run env (runTransaction (lookupSessionChildTx binding.request.runId)) >>= (@?= Left WorkspaceBindingConflict)
  ignored <-
    run
      env
      ( runTransaction do
          _ <- Workspaces.freezeWorkspaceTx binding binding.request.owner binding.request.epoch
          lookupSessionChildTx binding.request.runId
      )
  ignored @?= Left WorkspaceBindingConflict
  replace retained
  control <- right =<< run env (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
  fmap Workspaces.workspaceFrozen control @?= Just False
  run env (runTransaction (lookupSessionChildTx binding.request.runId)) >>= (@?= Right (Just original))

workspacePages :: DatabaseFixture -> IO ()
workspacePages fixture = withWorkspace fixture \env _ _ binding _ -> do
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy binding.repository binding.source [binding.base] binding.base binding.policyRevision])
  repository <- right (resolveRepository catalog binding.repository Nothing)
  siblings <- forM [1 .. 21 :: Int] \number -> do
    let request = binding.request & #runId .~ WorkflowId ("list-page-" <> Text.pack (show number)) & #assignment .~ Nothing
    fst <$> (right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx (workspaceLocatorPath binding.storageRoot) request repository)))
  (foreignRoot, _) <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx (workspaceLocatorPath binding.storageRoot <> "-other") (binding.request & #runId .~ WorkflowId "foreign-root-page" & #assignment .~ Nothing) repository))
  first <- right =<< run env (runTransaction (listWorkspacesTx (workspaceLocatorPath binding.storageRoot) Nothing))
  length first @?= 20
  let cursor = (.workspace.resource) (last first)
  second <- right =<< run env (runTransaction (listWorkspacesTx (workspaceLocatorPath binding.storageRoot) (Just (workspaceCoordinateText cursor))))
  length second @?= 2
  let resources = map (.workspace.resource) (first <> second)
  assertBool "foreign storage root is absent" (foreignRoot.workspace.resource `notElem` resources)
  mapM_ (\known -> length (filter (== known.workspace.resource) resources) @?= 1) (binding : siblings)
