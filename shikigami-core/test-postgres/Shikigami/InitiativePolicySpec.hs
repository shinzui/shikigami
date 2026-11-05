{-# LANGUAGE DataKinds #-}

module Shikigami.InitiativePolicySpec (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Duration (remainingDuration)
import Shikigami.Execution.Resources (Dimension (..))
import Shikigami.Initiative.Policy
import Shikigami.Initiative.Types
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Types qualified as Objective
import Shikigami.Repository (RepositoryId, repositoryId)
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.StateRevision (advanceRevision, initialRevision)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "InitiativePolicy"
    [ testCase "install refuses each invalid document" $ withEnv fixture \env -> do
        let attempt label context document expected =
              runAppIO env (installPolicy operator context document) >>= \case
                Right (Left refusal) -> (label :: Text, refusal) @?= (label, expected)
                other -> assertFailure (Text.unpack label <> ": " <> show (fmap (fmap (const ())) other))
        attempt "unknown principal" context {principalActive = const False} (document valid) UnknownPrincipal
        attempt "principal cannot create" context {objectives = Objective.defaultObjectiveSettings & #enabled .~ Objective.ObjectivesEnabled} (document valid) PrincipalCannotCreateObjectives
        attempt "repository outside the catalog" context (document valid {repositoryNames = ["repo_other"]}) (UnknownRepository (repositoryId "repo_other"))
        attempt "unknown coordinator" context (document valid {coordinatorName = "nobody"}) (UnknownCoordinator (name "nobody"))
        attempt "coordinator cannot coordinate" context {declarations = [coordinatorDecl & #behavior .~ Deterministic {rule = "x", params = Map.empty}]} (document valid) (CoordinatorNotCoordinating (name "coordinator"))
        attempt "coordinator without an identity" context {declarations = [coordinatorDecl & #identity .~ Nothing]} (document valid) CoordinatorHasNoIdentity
        attempt "no model attempts" context (document valid {perObjectiveLimits = object ["ActiveWork" .= (1 :: Int), "Tokens" .= unbounded, "CostMicroUsd" .= unbounded]}) EnvelopeDeniesModelAttempts
        attempt "a finite cost" context (document valid {perObjectiveLimits = limits 2 (9 :: Int)}) EnvelopeDeniesModelAttempts
        attempt "total below per-objective" context (document valid {perObjectiveLimits = limits' 2, totalLimits = limits' 1}) (TotalBelowPerObjective ModelAttempts)
        attempt "expiry in the past" context (document valid {expiry = addUTCTime (-1) now}) ExpiryInPast
        attempt "expiry beyond the lifetime" context (document valid {expiry = addUTCTime (31 * 86400) now}) ExpiryTooFar,
      testCase "unknown fields are refused by the document itself" $ do
        let refused = eitherDecode @PolicyInput (encode (objectWith ["surprise" .= True] valid))
        assertBool "unknown field" (either (const True) (const False) refused),
      testCase "a valid install is stored, live and pinned to its recomputed digest" $ withEnv fixture \env -> do
        policy <- install env valid
        let facts = policyFacts policy
        facts.digest @?= policyDigestFor facts.input
        (policyView now policy).state @?= "live"
        run env (readPolicy facts.policyId) >>= \case
          Right (Just stored) -> stored @?= policy
          other -> assertFailure (show other),
      testCase "a stale revocation refuses; a revocation empties coverage and refuses the fresh read" $ withEnv fixture \env -> do
        policy <- install env valid
        let identifier = (policyFacts policy).policyId
        runAppIO env (revokePolicy operator identifier (advanceRevision initialRevision) now) >>= (@?= Right (Left PolicyConflict))
        length <$> run env (coveringPolicies principal ChatFixture now) >>= (@?= 1)
        Right (Right view) <- runAppIO env (revokePolicy operator identifier initialRevision now)
        view.state @?= "revoked"
        length <$> run env (coveringPolicies principal ChatFixture now) >>= (@?= 0)
        proposal <- storedProposal env
        run env (reserveAdmission proposal identifier requested now) >>= (@?= Left (PolicyGone PolicyRevoked)),
      testCase "the admission window counts and a later instant frees it" $ withEnv fixture \env -> do
        policy <- install env valid {admissionLimit = 1}
        let identifier = (policyFacts policy).policyId
        first' <- reserveFresh env identifier now
        assertBool (show first') (either (const False) (const True) first')
        reserveFresh env identifier (addUTCTime 1 now) >>= (@?= Left (AdmissionsExhausted 1))
        later <- reserveFresh env identifier (addUTCTime 3601 now)
        assertBool (show later) (either (const False) (const True) later),
      testCase "totals are reserved one whole envelope at a time" $ withEnv fixture \env -> do
        policy <- install env valid {perObjectiveLimits = limits' 2, totalLimits = limits' 3}
        let identifier = (policyFacts policy).policyId
        first' <- reserveFresh env identifier now
        assertBool (show first') (either (const False) (const True) first')
        reserveFresh env identifier now >>= (@?= Left (TotalsExhausted ModelAttempts)),
      testCase "a reservation outside the policy's choices is not covered" $ withEnv fixture \env -> do
        policy <- install env valid
        proposal <- storedProposal env
        let other = requested {repository = repositoryId "repo_billing"} :: RequestedAuthority
        run env (reserveAdmission proposal (policyFacts policy).policyId other now) >>= (@?= Left NotCovered),
      testCase "two connections reserving one proposal yield one row and one refusal" $ withEnv fixture \env -> do
        policy <- install env valid
        proposal <- storedProposal env
        gates <- traverse (const newEmptyMVar) [(), ()]
        forM_ gates \gate -> forkIO (run env (reserveAdmission proposal (policyFacts policy).policyId requested now) >>= putMVar gate)
        results <- traverse takeMVar gates
        length [() | Right _ <- results] @?= 1
        length [() | Left (AlreadyAdmitted _) <- results] @?= 1,
      testCase "a policy that expired after being read as covering refuses at reservation" $ withEnv fixture \env -> do
        policy <- install env valid
        proposal <- storedProposal env
        let afterExpiry = addUTCTime 86401 now
        length <$> run env (coveringPolicies principal ChatFixture now) >>= (@?= 1)
        run env (reserveAdmission proposal (policyFacts policy).policyId requested afterExpiry) >>= (@?= Left (PolicyGone PolicyExpired)),
      testCase "an admission records its stages and retains its failure" $ withEnv fixture \env -> do
        policy <- install env valid
        proposal <- storedProposal env
        _ <- run env (reserveAdmission proposal (policyFacts policy).policyId requested now)
        run env (readReservation proposal) >>= \case
          Just reservation -> reservation.digest @?= (policyFacts policy).digest
          Nothing -> assertFailure "no retained reservation"
        run env (recordAdmissionStage proposal (AdmissionFailed CreationDenied "denied") now)
        Just stored <- run env (readAdmission proposal)
        stored.stage @?= "refused"
        stored.refusal @?= Just "creation-denied: denied"
    ]

reserveFresh :: AppEnv -> StandingPolicyId -> UTCTime -> IO (Either AdmissionRefusal Reservation)
reserveFresh env identifier at = do
  proposal <- storedProposal env
  run env (reserveAdmission proposal identifier requested at)

-- | An admission references a real proposal row, so its reservation can.
storedProposal :: AppEnv -> IO ProposalId
storedProposal env = do
  proposal <- newProposalId
  run
    env
    ( Tx.statement
        (proposalIdText proposal)
        ( preparable
            "INSERT INTO shikigami.initiative_proposals (proposal_id,proposal_key,observer,source,subject_kind,subject_id,assessment,requested,status,status_detail,proposed_at,expires_at,revision,run_workflow_id) VALUES ($1,$1,'agent_proposer','fixture/chat','chat',$1,'{}','{}','refused','{}',now(),now(),0,'run')"
            (E.param (E.nonNullable E.text))
            D.noResult
        )
    )
  pure proposal

install :: AppEnv -> Doc -> IO StandingPolicy
install env terms =
  runAppIO env (installPolicy operator context (document terms)) >>= either (assertFailure . show) (either (assertFailure . show) pure)

withEnv :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withEnv fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}

run :: AppEnv -> Transaction value -> IO value
run env transaction = runAppIO env (runTransaction transaction) >>= either (assertFailure . show) pure

now :: UTCTime
now = UTCTime (fromGregorian 2026 11 4) 3600

principal :: AgentPrincipal
principal = either (error . Text.unpack) id (mkAgentPrincipal "agent_proposer")

operator :: Objective.OperatorId
operator = either (error . Text.unpack) id (Objective.parseOperatorId "local-operator")

name :: Text -> AgentName
name = either (error . show) id . mkAgentName

coordinatorDecl :: AgentDecl
coordinatorDecl =
  (Fixture.successSpecialist "coordinator")
    & #behavior .~ Flow {name = declarationCoordinate "adaptive-delivery"}
    & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_coordinator"))

context :: PolicyContext
context =
  PolicyContext
    { principalActive = const True,
      objectives = Objective.defaultObjectiveSettings & #enabled .~ Objective.ObjectivesEnabled & #agentCreation .~ [principal],
      catalog = [repository, repositoryId "repo_billing"],
      declarations = [coordinatorDecl],
      now,
      maximumLifetime = remainingDuration (30 * 86400)
    }

repository :: RepositoryId
repository = repositoryId "repo_payments"

requested :: RequestedAuthority
requested = RequestedAuthority {repository, actionClass = ReproduceAndDiagnose, limits = Map.empty, objectiveWindow = remainingDuration 0}

unbounded :: Text
unbounded = "unbounded"

limits :: Int -> Int -> Value
limits attempts cost = object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= attempts, "Tokens" .= unbounded, "CostMicroUsd" .= cost]

limits' :: Int -> Value
limits' attempts = object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= attempts, "Tokens" .= unbounded, "CostMicroUsd" .= unbounded]

-- | The terms a case varies, before the document decoder checks them.
data Doc = Doc
  { repositoryNames :: ![Text],
    coordinatorName :: !Text,
    perObjectiveLimits :: !Value,
    totalLimits :: !Value,
    admissionLimit :: !Int,
    expiry :: !UTCTime
  }

valid :: Doc
valid =
  Doc
    { repositoryNames = ["repo_payments"],
      coordinatorName = "coordinator",
      perObjectiveLimits = limits' 2,
      totalLimits = limits' 20,
      admissionLimit = 10,
      expiry = addUTCTime 86400 now
    }

objectWith :: [Pair] -> Doc -> Value
objectWith extra terms =
  object
    ( [ "principal" .= principalText principal,
        "sources" .= (["chat-fixture"] :: [Text]),
        "repositories" .= terms.repositoryNames,
        "actionClasses" .= (["reproduce-and-diagnose"] :: [Text]),
        "coordinator" .= terms.coordinatorName,
        "perObjective" .= terms.perObjectiveLimits,
        "objectiveWindow" .= (7200 :: Int),
        "total" .= terms.totalLimits,
        "admissionsPerWindow" .= terms.admissionLimit,
        "window" .= (3600 :: Int),
        "expiresAt" .= terms.expiry
      ]
        <> extra
    )

document :: Doc -> PolicyInput
document = either error id . eitherDecode . encode . objectWith []
