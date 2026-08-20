module Shikigami.RunEvidenceSpec (tests) where

import Data.Text qualified as Text
import Shikigami.Attestation.Agent
import Shikigami.Attestation.Evidence
import Shikigami.Attestation.Profile
import Shikigami.Attestation.Reviewed
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Prelude
import Shikigami.RunEvidence.Conformance (runEvidenceBehaviorConformancePassed)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "run evidence"
    [ testGroup
        "lifecycle"
        [ testCase "all generated state-command obligations have passing witnesses" do
            assertEqual "behavior conformance" True runEvidenceBehaviorConformancePassed,
          testCase "every ordinary transition follows the checked aggregate" do
            profiled <- advancesTo ProfileResolved sampleEvidence
            running <- advancesTo Running profiled
            sealed <- advancesTo EvidenceSealed running
            _attested <- advancesTo Attested sealed
            pure (),
          testCase "each failure verdict is reachable only from running" do
            running <- runningEvidence
            mapM_ (assertTarget running) [NonConforming, Incomplete, Failed],
          testCase "requested cannot seal" do
            transitionEvidence sampleEvidence EvidenceSealed
              `assertTransitionError` IllegalTransition Requested EvidenceSealed,
          testCase "attested is reachable only from evidence-sealed" do
            running <- runningEvidence
            transitionEvidence running Attested
              `assertTransitionError` IllegalTransition Running Attested,
          testCase "attested evidence cannot be reopened" do
            running <- runningEvidence
            sealed <- advancesTo EvidenceSealed running
            attested <- advancesTo Attested sealed
            transitionEvidence attested Running
              `assertTransitionError` IllegalTransition Attested Running
        ]
    ]

assertTarget :: RunEvidence -> EvidencePhase -> IO ()
assertTarget evidence target = do
  advanced <- advancesTo target evidence
  assertEqual "target phase" target (phase advanced)

runningEvidence :: IO RunEvidence
runningEvidence = do
  profiled <- advancesTo ProfileResolved sampleEvidence
  advancesTo Running profiled

advancesTo :: EvidencePhase -> RunEvidence -> IO RunEvidence
advancesTo target evidence =
  case transitionEvidence evidence target of
    Left err -> assertFailure ("unexpected transition error: " <> show err)
    Right advanced -> pure advanced

assertTransitionError :: Either TransitionError RunEvidence -> TransitionError -> IO ()
assertTransitionError actual expected =
  case actual of
    Left err -> assertEqual "transition error" expected err
    Right advanced -> assertFailure ("transition unexpectedly reached " <> show (phase advanced))

sampleEvidence :: RunEvidence
sampleEvidence =
  requestEvidence
    sampleAggregateId
    (runCorrelationId "run-evidence-m1")
    sampleAgentVersion
    (declarationOnlyArtifacts (DeclarationDigest "sha256:declaration"))
    sampleReviewed
    sampleProfileRef
    (ReviewRequestId "review-request-1")
    "review-request-1:attempt-1"

sampleAggregateId :: RunEvidenceId
sampleAggregateId =
  either (error . show) id (parseRunEvidenceId "runevidence_01h455vb4pex5vsknk084sn02q")

sampleAgentVersion :: AgentVersionRef
sampleAgentVersion =
  AgentVersionRef
    { logicalAgentId = LogicalAgentId "reviewer",
      agentVersion = AgentVersion "v1",
      declarationDigest = DeclarationDigest "sha256:declaration"
    }

sampleReviewed :: ReviewedArtifact
sampleReviewed =
  ReviewedArtifact
    { repository = RepositoryId "mori://shinzui/shikigami",
      baseCommit = fullCommit 'a',
      headCommit = fullCommit 'b',
      diffDigest = DiffDigest "sha256:diff",
      pathScope = [],
      pullRequest = Nothing
    }

fullCommit :: Char -> FullCommit
fullCommit character =
  either (error . show) id (mkFullCommit (replicateText 40 character))

replicateText :: Int -> Char -> Text
replicateText count character = Text.pack (replicate count character)

sampleProfileRef :: SanctionedExecutionProfileRef
sampleProfileRef =
  SanctionedExecutionProfileRef
    { profileId = ProfileId "review",
      version = ProfileVersion "v1",
      digest = ProfileDigest "sha256:profile"
    }
