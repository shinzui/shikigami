module Shikigami.AdaptiveProposalSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Coordination.Proposal
import Shikigami.Coordination.Validate
import Shikigami.Decision.ModelAlias (parseModelAlias)
import Shikigami.Fixture.ExecutionIdentity
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Shikigami.WorkerSession.Types qualified
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Value (workspaceCoordinate)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "AdaptiveProposal"
    [ testCase "small and large cases select distinct bounded organizations" do
        small <- right (validate (proposal [CreateAssignment (placement "small" Nothing [])]))
        large <- right (validate (proposal [CreateAssignment localPlacement, CreateAssignment (placement "child" (Just (key "local")) [])]))
        length small.arrangement @?= 1
        length large.arrangement @?= 2
        assertBool "independent immutable operation keys" (small.operations /= large.operations),
      testCase "unknown targets, owners and hierarchy parents refuse" do
        forM_
          [ placement "a" Nothing [] & #target .~ name "forbidden",
            placement "a" Nothing [] & #assignment . #owner .~ identity "forbidden",
            placement "a" (Just (key "missing")) []
          ]
          \value ->
            assertBool "refused before effects" (isLeft (validate (proposal [CreateAssignment value]))),
      testCase "dependency and hierarchy cycles refuse as a whole" do
        forM_
          [ [placement "a" Nothing [key "b"], placement "b" Nothing [key "a"]],
            [placement "a" (Just (key "b")) [], placement "b" (Just (key "a")) []]
          ]
          \graph ->
            assertBool "cycle refused" (isLeft (validate (proposal (map CreateAssignment graph)))),
      testCase "depth and assignment bounds refuse" do
        let input = proposal [CreateAssignment localPlacement, CreateAssignment (placement "b" (Just (key "local")) [])]
        assertBool "depth" (isLeft (validateProposal now (policy & #maximumDepth .~ 1) [] objective input))
        assertBool "count" (isLeft (validateProposal now (policy & #maximumAssignments .~ 1) [] objective input)),
      testCase "split and consolidate preserve old identities as withdrawn and admit bounded replacement work" do
        let a = placement "a" Nothing []
            b = placement "b" Nothing []
            asAssignment node = Assignment node.assignment initialRevision initialRevision initialRevision []
            existing = objective & #assignments .~ map asAssignment [a, b]
        consolidated <- right (validateProposal now policy [a, b] existing (proposal [ConsolidateAssignments [key "a", key "b"] (placement "combined" Nothing [])]))
        map (.assignment.state) consolidated.arrangement @?= [Withdrawn, Withdrawn, Pending]
        split <- right (validateProposal now policy [a] (objective & #assignments .~ [asAssignment a]) (proposal [SplitAssignment (key "a") [placement "one" Nothing [], placement "two" Nothing []]]))
        map (.assignment.state) split.arrangement @?= [Withdrawn, Pending, Pending],
      testCase "replacement work cannot leave a live dependency on a withdrawn assignment" do
        let a = placement "a" Nothing []
            b = placement "b" Nothing [key "a"]
            existing = objective & #assignments .~ [Assignment node.assignment initialRevision initialRevision initialRevision [] | node <- [a, b]]
        assertBool "whole final graph refused" (isLeft (validateProposal now policy [a, b] existing (proposal [SplitAssignment (key "a") [placement "one" Nothing [], placement "two" Nothing []]]))),
      testCase "the initial sessionless coordinator is bound to the admitted root and cutoff" do
        let node = placement "coordinator" Nothing [] & #target .~ policy.coordinator & #assignment . #owner .~ policy.identity & #assignment . #rootId .~ Nothing & #assignment . #cutoff .~ Nothing
            existing = objective & #assignments .~ [Assignment node.assignment initialRevision initialRevision initialRevision []]
        accepted <- right (validateProposal now policy [node] existing (proposal [ChangeConcurrency 1]))
        map (.assignment.rootId) accepted.arrangement @?= [Just policy.rootId]
        map (.assignment.cutoff) accepted.arrangement @?= [Just policy.cutoff],
      testCase "stale checkpoint, instructions and criteria refuse" do
        forM_ [input & #checkpointRevision %~ advanceRevision, input & #instructionsRevision %~ advanceRevision, input & #criteriaRevision %~ advanceRevision] \value -> validate value @?= Left ObjectiveConflict,
      testCase "missing evidence, forbidden concurrency and completion without combined checks refuse" do
        assertBool "evidence" (isLeft (validate (input & #evidence .~ [evidenceKey "missing"])))
        forM_ [0, 3, -1] \bound -> assertBool "concurrency" (isLeft (validate (proposal [ChangeConcurrency bound])))
        assertBool "no fake all-green completion" (isLeft (validate (proposal [ProposeCompletion (IntegratedAcceptance initialRevision initialRevision initialRevision [artifact "combined"] [] [])]))),
      testCase "forbidden models and unfenced session restructuring refuse" do
        let node = placement "existing" Nothing []
            assignment = Assignment node.assignment initialRevision initialRevision initialRevision []
            existing = objective & #assignments .~ [assignment]
            escalation = proposal [EscalateModel (key "existing") (checked (parseModelAlias "forbidden"))]
        assertBool "model" (isLeft (validateProposal now policy [node] existing escalation))
        let session = Shikigami.WorkerSession.Types.workerSessionId "bound-session"
            bound = existing & #assignments .~ [assignment & #definition . #sessionId .~ Just session]
        assertBool "ownership fence" (isLeft (validateProposal now policy [node] bound (proposal [NarrowAssignment (key "existing") (checked (parseInstructions "narrow"))])))
        let workspace = WorkspaceRef (workspaceCoordinate "shikigami.workspace/1") (workspaceCoordinate "retained-workspace")
            transfer = proposal [TransferAssignment (key "existing") (name "local") workspace]
        assertBool "unlisted workspace refused" (isLeft (validateProposal now policy [node] bound transfer))
        _ <- right (validateProposal now (policy & #workspaces .~ [(key "existing", workspace)]) [node] bound transfer)
        pure (),
      testCase "repeating an ancestor role is a hierarchy cycle even with distinct assignment ids" do
        let input = proposal [CreateAssignment (placement "a" Nothing []), CreateAssignment (placement "b" (Just (key "a")) [])]
            selfDelegating = policy & #targets .~ [target & #parents .~ [name "coordinator", name "worker"]]
        assertBool "role cycle refused" (isLeft (validateProposal now selfDelegating [] objective input)),
      testCase "a model permission cannot be borrowed from a sibling role sharing its principal" do
        let node = placement "existing" Nothing []
            assignment = Assignment node.assignment initialRevision initialRevision initialRevision []
            expensive = checked (parseModelAlias "specialist-model")
            roles = policy & #targets .~ [target, target & #name .~ name "specialist" & #models .~ [expensive]]
            existing = objective & #assignments .~ [assignment]
        assertBool "role-scoped model refused" (isLeft (validateProposal now roles [node] existing (proposal [EscalateModel (key "existing") expensive]))),
      testCase "catalog parent allow-list and cutoff constrain proposals" do
        assertBool "parent" (isLeft (validateProposal now (policy & #targets .~ [target & #parents .~ []]) [] objective input))
        assertBool "cutoff" (isLeft (validateProposal cutoff policy [] objective input)),
      testCase "a retained named role survives another pinned role sharing its principal" do
        let node = placement "existing" Nothing []
            assignment = Assignment node.assignment initialRevision initialRevision initialRevision []
            roles = policy & #targets .~ [target, target & #name .~ name "specialist"]
            existing = objective & #assignments .~ [assignment]
        currentArrangement roles (Just [node]) existing @?= Right [node],
      testCase "unknown proposal fields and arbitrary code have no decoder" do
        let unknown = Aeson.object ["tag" .= ("RunCode" :: Text), "contents" .= ("curl secret" :: Text)]
        assertBool "closed sum" (case Aeson.fromJSON unknown :: Aeson.Result Change of Aeson.Error _ -> True; _ -> False)
        Aeson.fromJSON (toJSON input) @?= Aeson.Success input
        Aeson.fromJSON (toJSON policy) @?= Aeson.Success policy
    ]
  where
    input = proposal [CreateAssignment (placement "a" Nothing [])]
    validate = validateProposal now policy [] objective

now, cutoff :: UTCTime
now = UTCTime (fromGregorian 2026 11 3) 0
cutoff = UTCTime (fromGregorian 2027 1 1) 0

name :: Text -> AgentName
name = checked . mkAgentName

identity :: Text -> AgentIdentity
identity = compatibilityIdentity . name

key :: Text -> ObjectiveAssignmentId
key = checked . parseObjectiveAssignmentId

evidenceKey :: Text -> EvidenceKey
evidenceKey = checked . parseEvidenceKey

artifact :: Text -> ArtifactRef
artifact = checked . parseArtifactRef

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

target :: Target
target = Target (name "worker") (identity "worker") [name "coordinator", name "local"] [checked (parseModelAlias "allowed")]

policy :: Policy
policy = Policy V1 (name "coordinator") (identity "coordinator") (fixtureRootId "root") cutoff [target, Target (name "local") (identity "local") [name "coordinator"] []] [] 4 16 2

placement :: Text -> Maybe ObjectiveAssignmentId -> [ObjectiveAssignmentId] -> Placement
placement label parent dependencies = Placement (AssignmentDraft (key label) (checked (parseInstructions "bounded work")) dependencies (identity "worker") Pending Nothing (Just policy.rootId) (Just cutoff)) (name "worker") parent

localPlacement :: Placement
localPlacement = placement "local" Nothing [] & #target .~ name "local" & #assignment . #owner .~ identity "local"

objective :: Objective
objective = Objective (checked (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) actor [Member actor [Owner], Member (RecordedAgent (identity "worker")) [Worker], Member (RecordedAgent (identity "local")) [Coordinator]] (checked (parseTitle "deliver")) (checked (parseGoal "deliver")) (checked (parseInstructions "instructions")) initialRevision initialRevision initialRevision [Criterion (checked (parseCriterionKey "combined")) (checked (parseCriterionDescription "combined check")) Automatic JourneyRequired] Open [] [] [] [] [] [] [] [] Nothing Nothing
  where
    actor = RecordedAgent policy.identity

proposal :: [Change] -> Proposal
proposal changes = Proposal V1 objective.objectiveId objective.revision objective.instructionsRevision objective.criteriaRevision (fixtureOperationId "decision") [] (checked (parseCriterionDescription "evidence changed")) Nothing (checked (parseCriterionDescription "bounded benefit")) (evidenceKey "later-check") changes
