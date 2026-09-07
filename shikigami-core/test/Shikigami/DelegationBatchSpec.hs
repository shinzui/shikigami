module Shikigami.DelegationBatchSpec (tests) where

import Data.Aeson (Value (Null))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Keiro.Workflow (WorkflowId (..))
import Kioku.Id qualified as NominalId
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    AmbiguousPolicy (ReturnAmbiguous),
    Behavior (..),
    NoMatchPolicy (ReturnNoMatch),
    RouterConfidence (RoutingMedium),
    RouterPolicy (..),
    Trigger (..),
    defaultDelegationBudget,
    defaultMemoryPolicy,
  )
import Shikigami.Agent.Delegate
  ( DelegationBatchPreflightError (..),
    DelegationRequest (..),
    PreparedDelegation (..),
    delegatedWorkflowId,
    preflightDelegationBatch,
  )
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Directory (DirectorySnapshotVersion (..), DirectorySourceKind (DirectoryDisabledSource))
import Shikigami.Router.Catalog
  ( CandidateAvailability (..),
    CandidateCatalog (..),
    CandidateEntry (..),
    CatalogVersion (..),
    ExclusionReason (Paused),
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "DelegationBatch"
    [ testCase "preflight computes every deterministic child id in selection order" do
        let requests = batchRequest "first-key" "first" NonEmpty.:| [batchRequest "second-key" "second"]
            expectedIds =
              [ delegatedWorkflowId parentWorkflowId "first" "first-key",
                delegatedWorkflowId parentWorkflowId "second" "second-key"
              ]
        case preflightDelegationBatch routerDecl delegateCtx catalog parentWorkflowId requests of
          Left errors -> assertFailure ("expected valid batch, got " <> show errors)
          Right prepared ->
            assertEqual
              "child ids are all computed before reservation"
              expectedIds
              [childWorkflowId | PreparedDelegation {childWorkflowId} <- NonEmpty.toList prepared],
      testCase "preflight accumulates fan-out, duplicate-key, catalog, and governance failures" do
        let constrained = routerDecl {routing = Just routerPolicy {maxSelections = 1}}
            requests =
              batchRequest "same-key" "first"
                NonEmpty.:| [ batchRequest "same-key" "paused",
                              batchRequest "third-key" "intruder"
                            ]
        case preflightDelegationBatch constrained delegateCtx catalog parentWorkflowId requests of
          Right _ -> assertFailure "expected the complete batch to be rejected"
          Left errors -> do
            let found = NonEmpty.toList errors
            assertBool "fan-out is checked" (DelegationBatchSelectionLimitExceeded 3 1 `elem` found)
            assertBool "stable keys are distinct" (DelegationBatchDuplicateKey "same-key" `elem` found)
            assertBool "recorded availability is checked" (DelegationBatchCatalogTargetUnavailable "paused" Paused `elem` found)
            assertBool "missing catalog targets are checked" (DelegationBatchCatalogTargetMissing "intruder" `elem` found)
            assertBool
              "the declaration allow-list remains authoritative"
              (DelegationBatchGovernanceRejected (Just "intruder") (DelegationNotAllowed "intruder") `elem` found),
      testCase "preflight checks complete lineage, depth, and parent session before reservation" do
        let blockedCtx = delegateCtx {depth = DelegationDepth 3, sessionId = Nothing, lineage = map AgentName ["root", "first"]}
        case preflightDelegationBatch routerDecl blockedCtx catalog parentWorkflowId (batchRequest "cycle" "first" NonEmpty.:| []) of
          Right _ -> assertFailure "expected lineage, depth, and session rejection"
          Left errors -> do
            let found = NonEmpty.toList errors
            assertBool "the parent session is required" (DelegationBatchSessionMissing `elem` found)
            assertBool
              "the depth bound is checked before reservation"
              (DelegationBatchGovernanceRejected Nothing (DelegationDepthExceeded 4) `elem` found)
            assertBool
              "the complete ancestor lineage is checked"
              (DelegationBatchGovernanceRejected (Just "first") (DelegationCycleDetected "first") `elem` found)
    ]

batchRequest :: Text -> Text -> DelegationRequest
batchRequest key target = DelegationRequest {key, target, payload = Null}

parentWorkflowId :: WorkflowId
parentWorkflowId = WorkflowId "router-parent"

delegateCtx :: DelegateCtx
delegateCtx =
  DelegateCtx
    { identity = compatibilityIdentity "router",
      depth = DelegationDepth 0,
      sessionId = Just nominalSessionFixture,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      lineage = map AgentName ["router"],
      delegationBudgetId = Nothing,
      budgetLimit = defaultDelegationBudget
    }

routerDecl :: AgentDecl
routerDecl =
  AgentDecl
    { name = "router",
      description = "batch routing fixture",
      trigger = Event {eventType = "test"},
      behavior = Deterministic {rule = "test", params = mempty},
      sinks = [],
      delegates = ["first", "second", "paused"],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      routing = Just routerPolicy
    }

routerPolicy :: RouterPolicy
routerPolicy =
  RouterPolicy
    { maxSelections = 2,
      minimumConfidence = RoutingMedium,
      onNoMatch = ReturnNoMatch,
      onAmbiguous = ReturnAmbiguous
    }

catalog :: CandidateCatalog
catalog =
  CandidateCatalog
    { router = "router",
      version = CatalogVersion "catalog-v1",
      lifecycleSource = DirectoryDisabledSource,
      lifecycleSourceVersion = DirectorySnapshotVersion "directory-v1",
      candidates =
        [ candidate "first" Available,
          candidate "second" Available,
          candidate "paused" (Excluded Paused)
        ],
      unassociatedLoadFailures = 0
    }

candidate :: Text -> CandidateAvailability -> CandidateEntry
candidate name availability =
  CandidateEntry
    { name,
      description = Just name,
      expertise = [],
      availability
    }

nominalSessionFixture :: NominalId.SessionId
nominalSessionFixture = either (error . show) id (NominalId.parseId "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
