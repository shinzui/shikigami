module Shikigami.AdaptiveDeliverySpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.Either (isLeft, rights)
import Data.Generics.Labels ()
import Data.IORef
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal qualified
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Coordination.Checkpoint qualified as CP
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Validate (validateProposal)
import Shikigami.Execution.Quantity (zeroAmount)
import Shikigami.Execution.Resources qualified
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Transcript (executionIdentity)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command
import Shikigami.Objective.Store qualified as ObjectiveStore
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Types (SessionAdmission (..))
import Shikigami.WorkerSession.Types qualified as Session
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "AdaptiveDelivery"
    [ testCase "production checkpoint commits graph and executable manifest together; restart reads the committed decision before fresh policy" $
        withCheckpoint fixture \env host provider policy objective proposal _ -> do
          originalRoot <- right =<< run env (Roots.inspectRoot policy.rootId)
          decision <- right =<< provider.accept proposal
          length decision.operations @?= 1
          after <- right =<< readObjective env host objective
          length after.assignments @?= 1
          after.revision @?= advanceRevision proposal.checkpointRevision
          -- Rebuild every adapter with unavailable live registration. A retained
          -- decision remains readable; the callback must not be invoked.
          calls <- newIORef (0 :: Int)
          let rebuilt = CP.checkpointProvider env host policy (modifyIORef' calls (+ 1) >> pure (Left ObjectiveUnavailable))
          rebuilt.accept proposal >>= (@?= Right decision)
          readIORef calls >>= (@?= 0)
          rebuilt.observe objective proposal.operationId >>= (@?= Right (Just decision))
          run env (Roots.inspectRoot policy.rootId) >>= (@?= Right originalRoot),
      testCase "a corrupted manifest refuses against its original objective receipt without new work" $
        withCheckpoint fixture \env _ provider _ objective proposal _ -> do
          accepted <- right =<< provider.accept proposal
          let corrupt = preparable "UPDATE shikigami.adaptive_decisions SET manifest=jsonb_set(manifest,'{operations}','[]'::jsonb)" E.noParams D.noResult
              restore = preparable "UPDATE shikigami.adaptive_decisions SET manifest=$1" (E.param (E.nonNullable E.jsonb)) D.noResult
          run env (runTransaction (Tx.statement () corrupt))
          provider.observe objective proposal.operationId >>= (@?= Left ObjectiveUnavailable)
          provider.accept proposal >>= (@?= Left ObjectiveUnavailable)
          run env (runTransaction (Tx.statement (toJSON accepted) restore))
          provider.observe objective proposal.operationId >>= (@?= Right (Just accepted)),
      testCase "an unprojected continuing session is not mistaken for an unfenced assignment" $
        withCheckpoint fixture \env host provider policy objective proposal admission -> do
          _ <- right =<< provider.accept proposal
          current <- right =<< readObjective env host objective
          assignment <- case current.assignments of [value] -> pure value; _ -> assertFailure "expected one assignment"
          assignment.definition.sessionId @?= Nothing
          let source = admission & #objective .~ ObjectiveStore.referenceFor objective assignment.definition.assignmentId & #scope . #workerKey .~ Session.workerCoordinate "unprojected"
          _ <- right =<< run env (Sessions.openSession source)
          before <- right =<< run env (Roots.inspectRoot policy.rootId)
          let narrow = proposal & #checkpointRevision .~ current.revision & #operationId .~ fixtureOperationId "narrow-unprojected" & #changes .~ [P.NarrowAssignment assignment.definition.assignmentId (checked (parseInstructions "new work"))]
          assertBool "session source refuses restructuring" . isLeft =<< provider.accept narrow
          provider.observe objective narrow.operationId >>= (@?= Right Nothing)
          readObjective env host objective >>= (@?= Right current)
          run env (Roots.inspectRoot policy.rootId) >>= (@?= Right before),
      testCase "invalid target, dependency cycle, stale revision and exhausted root leave no assignments or accepted manifests" $
        withCheckpoint fixture \env host provider policy objective proposal _ -> do
          let placement = case proposal.changes of [P.CreateAssignment value] -> value; _ -> error "fixture"
          forM_
            [ proposal & #changes .~ [P.CreateAssignment (placement & #target .~ checked (mkAgentName "forbidden"))],
              proposal & #changes .~ [P.CreateAssignment (placement & #assignment . #dependencies .~ [placement.assignment.assignmentId])],
              proposal & #checkpointRevision %~ advanceRevision
            ]
            \invalid -> do
              assertBool "refused" . isLeft =<< provider.accept invalid
              provider.observe objective invalid.operationId >>= (@?= Right Nothing)
          current <- right =<< readObjective env host objective
          current.assignments @?= []
          current.revision @?= proposal.checkpointRevision
          root <- right =<< run env (Roots.inspectRoot policy.rootId)
          _ <- right =<< run env (Roots.setRootControl policy.rootId root.revision Shikigami.Execution.Resources.ContinueWork (Just zeroAmount))
          assertBool "last root slot exhausted" . isLeft =<< provider.accept proposal
          provider.observe objective proposal.operationId >>= (@?= Right Nothing)
          drained <- right =<< run env (Roots.inspectRoot policy.rootId)
          -- Cancellation and cutoff are authoritative at admission, regardless
          -- of the pinned proposal catalog.
          _ <- right =<< run env (Roots.setRootControl policy.rootId drained.revision Shikigami.Execution.Resources.StopWork Nothing)
          assertBool "root refused" . isLeft =<< provider.accept proposal
          provider.observe objective proposal.operationId >>= (@?= Right Nothing),
      testCase "concurrent checkpoint decisions at one revision admit only one; changed payload cannot reuse the winning key" $
        withCheckpoint fixture \env host provider _ objective proposal _ -> do
          let other = proposal & #operationId .~ fixtureOperationId "competing-decision"
          (a, b) <- concurrently (provider.accept proposal) (provider.accept other)
          length (rights [a, b]) @?= 1
          current <- right =<< readObjective env host objective
          length current.assignments @?= 1
          accepted <- case rights [a, b] of [value] -> pure value; _ -> assertFailure "expected exactly one admitted decision"
          provider.accept (accepted.proposal & #expectedBenefit .~ checked (parseCriterionDescription "different meaning")) >>= (@?= Left ObjectiveConflict),
      testCase "all-green children with a failing exact combined check cannot propose completion" $
        withCheckpoint fixture \env host provider policy objective proposal _ -> do
          _ <- right =<< provider.accept proposal
          current <- right =<< readObjective env host objective
          assignment <- case current.assignments of [value] -> pure value; _ -> assertFailure "expected one assignment"
          _ <- right =<< run env (O.executeCommand host objective current.revision (fixtureOperationId "child-done") (RecordProgress assignment.definition.assignmentId Done [] []))
          done <- right =<< readObjective env host objective
          -- Recording retained evidence spends no new execution slot. Metadata
          -- progress remains possible after execution admission is reduced to zero.
          root <- right =<< run env (Roots.inspectRoot policy.rootId)
          _ <- right =<< run env (Roots.setRootControl policy.rootId root.revision Shikigami.Execution.Resources.ContinueWork (Just zeroAmount))
          let artifact = checked (parseArtifactRef "combined-v1")
              key = checked (parseEvidenceKey "combined-check")
              criterion = checked (parseCriterionKey "integration")
              result = RetainedResult (runReference "combined-run") (executionIdentity "combined-execution") (resultCommitment "sha256:combined-v1") artifact
              evidence = ResultEvidence key criterion result JourneyObserved
              verifier = host & #verifyResult .~ (\actual -> pure (if actual == result then Right (EvidenceVerification CheckFailed (Just criterion) JourneyObserved) else Left ObjectiveInvalidEvidence))
              checking = CP.checkpointProvider env verifier policy (pure (Right ()))
              integrate = proposal & #operationId .~ fixtureOperationId "integrate-combined" & #checkpointRevision .~ done.revision & #changes .~ [P.IntegrateResult assignment.definition.assignmentId evidence]
          _ <- right =<< checking.accept integrate
          observed <- right =<< readObjective env host objective
          length observed.evidence @?= 1
          observed.status @?= Open
          let completion = P.IntegratedAcceptance observed.revision observed.instructionsRevision observed.criteriaRevision [artifact] [key] []
              close = proposal & #operationId .~ fixtureOperationId "propose-completion" & #checkpointRevision .~ observed.revision & #changes .~ [P.ProposeCompletion completion]
          checking.accept close >>= (@?= Left ObjectiveInvalidEvidence)
          checking.observe objective close.operationId >>= (@?= Right Nothing),
      testCase "revoking coordination stops protected replay and fresh dispatch authority" $
        withCheckpoint fixture \env host provider _ objective proposal _ -> do
          _ <- right =<< provider.accept proposal
          current <- right =<< readObjective env host objective
          _ <- right =<< run env (O.executeCommand ownerHost objective current.revision (fixtureOperationId "revoke-coordinator") (RevokeMember (RecordedAgent proposalOwner)))
          provider.observe objective proposal.operationId >>= (@?= Left ObjectiveDenied)
    ]
  where
    proposalOwner = Shikigami.Agent.Principal.compatibilityIdentity (checked (mkAgentName "coordinator"))

-- The test uses the actual objective provider and migrated PostgreSQL database.
-- The only fixture is the already-admitted target/lifecycle catalog.
withCheckpoint :: DatabaseFixture -> (AppEnv -> O.ObjectiveHost -> CP.Provider -> P.Policy -> ObjectiveId -> P.Proposal -> SessionAdmission -> IO a) -> IO a
withCheckpoint fixture callback = Fixture.withFixture fixture \env admission _ -> do
  let coordinator = admission.context.identity
      worker = admission.identity
      rootId = fromMaybe (error "fixture root") admission.context.executionRootId
  root <- right =<< run env (Roots.inspectRoot rootId)
  created <- right =<< run env (O.createObjective ownerHost (fixtureOperationId "adaptive-create") Nothing (CreateRequest (checked (parseTitle "deliver")) (checked (parseGoal "finite delivery")) (checked (parseInstructions "deliver exactly")) [Criterion (checked (parseCriterionKey "integration")) (checked (parseCriterionDescription "combined artifacts")) Automatic JourneyRequired] []))
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId initialRevision (fixtureOperationId "grant-coordinator") (GrantMember (RecordedAgent coordinator) [Coordinator]))
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId (advanceRevision initialRevision) (fixtureOperationId "grant-worker") (GrantMember (RecordedAgent worker) [Worker]))
  let host = ownerHost & #authenticate .~ pure (Right (RecordedAgent coordinator))
      policy = P.Policy V1 admission.delegator.name coordinator rootId root.envelope.cutoff [P.Target admission.worker worker [admission.delegator.name] []] [] 4 16 2
      provider = CP.checkpointProvider env host policy (pure (Right ()))
  checkpoint <- right =<< provider.current created.objectiveId
  let objective = checkpoint.objective
      placement = P.Placement (AssignmentDraft (checked (parseObjectiveAssignmentId "work")) (checked (parseInstructions "bounded work")) [] worker Pending Nothing (Just rootId) (Just policy.cutoff)) admission.worker Nothing
      proposal = P.Proposal V1 objective.objectiveId objective.revision objective.instructionsRevision objective.criteriaRevision (fixtureOperationId "adaptive-accept") [] (checked (parseCriterionDescription "small task")) Nothing (checked (parseCriterionDescription "one worker suffices")) (checked (parseEvidenceKey "later")) [P.CreateAssignment placement]
  callback env host provider policy objective.objectiveId proposal admission

ownerHost :: O.ObjectiveHost
ownerHost = O.ObjectiveHost (defaultObjectiveSettings & #enabled .~ ObjectivesEnabled) (pure (Right (VerifiedCaller (checked (parseCallerId "owner"))))) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

readObjective :: AppEnv -> O.ObjectiveHost -> ObjectiveId -> IO (Either ObjectiveError Objective)
readObjective env host objective = run env (O.readObjective host objective)
