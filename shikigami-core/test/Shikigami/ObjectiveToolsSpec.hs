{-# LANGUAGE DataKinds #-}

module Shikigami.ObjectiveToolsSpec (tests) where

import Control.Exception (try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Behavior.Error (TransientBehaviorFailure)
import Shikigami.Decision.ModelAlias (parseModelAlias)
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Coordinate (executionDigestFor)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Inspection (ObjectiveView (..))
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Tools qualified as Tools
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ObjectiveTools"
    [ testCase "scope roundtrip binds the original principal, memory, permissions and source assignment" do
        scope <- fixtureScope
        Aeson.eitherDecode (Aeson.encode scope) @?= Right scope
        assertBool "original execution matches" (Scope.matchesExecution scope scope.runId scope.identity scope.sessionId scope.rootId [] (assignmentIdFor "scope-codec"))
        assertBool "another assignment is outside the scope" (not (Scope.matchesExecution scope scope.runId scope.identity scope.sessionId scope.rootId [] (assignmentIdFor "other")))
        assertBool "different model permissions do not replace the original admission" (not (Scope.matchesExecution scope scope.runId scope.identity scope.sessionId scope.rootId [checked parseModelAlias "other"] (assignmentIdFor "scope-codec")))
        let changed = scope & #runId .~ WorkflowId "other"
        assertBool "source fingerprint changes" (Scope.scopeFingerprint changed /= Scope.scopeFingerprint scope),
      testCase "malformed scope, codec versions and invented cutoff fail closed" do
        scope <- fixtureScope
        now <- getCurrentTime
        forM_ [replace "format" (Aeson.Number 2), replace "actor" (Aeson.String "forged"), replace "creationPolicy" Aeson.Null, replace "cutoff" (toJSON now)] \change -> assertBool "invalid retained scope refused" (isLeft (resultEither (Aeson.fromJSON (change (toJSON scope)) :: Aeson.Result Scope.ObjectiveScope))),
      testCase "model arguments cannot supply actor, root, scope or operation authority" do
        let input = Aeson.object ["tag" .= ("InspectObjective" :: Text), "objectiveId" .= identifier, "after" .= (0 :: Int), "limit" .= (20 :: Int)]
        assertBool "closed read parses" (not (isLeft (resultEither (Aeson.fromJSON input :: Aeson.Result Tools.Input))))
        forM_ ["actor", "identity", "rootId", "cutoff", "scope", "operationKey", "operationId", "creationPolicy"] \field -> assertBool "injected field refused" (isLeft (resultEither (Aeson.fromJSON (replace field (Aeson.String "forged") input) :: Aeson.Result Tools.Input)))
        forM_ ["GrantMember", "RevokeMember", "ApplyObjectiveCommand", "TransferSessionOwnership"] \tag -> assertBool "administration/internal command unavailable to model" (isLeft (resultEither (Aeson.fromJSON (Aeson.object ["tag" .= (tag :: Text)]) :: Aeson.Result Tools.Input))),
      testCase "planning input cannot choose another owner or root" do
        let assignment = Aeson.object ["assignmentId" .= Aeson.object ["value" .= ("work" :: Text)], "instructions" .= ("work" :: Text), "dependencies" .= ([] :: [Text]), "state" .= ("Pending" :: Text)]
        assertBool "finite own assignment parses" (not (isLeft (resultEither (Aeson.fromJSON assignment :: Aeson.Result Tools.AssignmentInput))))
        forM_ ["owner", "rootId", "sessionId", "cutoff"] \field -> assertBool "runtime field cannot be selected" (isLeft (resultEither (Aeson.fromJSON (replace field Aeson.Null assignment) :: Aeson.Result Tools.AssignmentInput))),
      testCase "creation cannot appear in an originally non-creator menu" do
        scope <- fixtureScope
        let existing = scope & #target .~ Just identifier & #creationPolicy .~ Nothing & #permissions .~ [Scope.InspectObjectives, Scope.ApplyObjectiveCommands]
        assertBool "creation request is advertised only by the creator scope" ("CreateObjective" `Text.isInfixOf` Text.pack (show (Tools.inputSchema scope)))
        assertBool "ordinary scope keeps its original menu" (not ("CreateObjective" `Text.isInfixOf` Text.pack (show (Tools.inputSchema existing)))),
      testCase "model replies are bounded and unknown versions cannot replay" do
        let view = ObjectiveView (objectiveIdText identifier) "title" (Text.replicate 17000 "x") "Open" 0 0 0 0 0 0 [] [] [] [] [] Nothing
            reply = Operation.Reply V1 (Operation.ObjectiveInspected view)
        assertBool "oversized metadata is not returned to a model" (isLeft (Operation.bounded (Right reply)))
        assertBool "unknown reply codec refused" (isLeft (resultEither (Aeson.fromJSON (replace "format" (Aeson.Number 2) (toJSON reply)) :: Aeson.Result Operation.Reply))),
      testCase "uncertain command outcomes escape without a definitive journal result" do
        forM_ [ObjectiveUnavailable, ObjectiveUnresolved] \err -> do
          attempted <- try @TransientBehaviorFailure (Operation.requireResolved (Left err :: Either ObjectiveError ()))
          assertBool "same operation remains retryable" (isLeft attempted)
        Operation.requireResolved (Left ObjectiveDenied :: Either ObjectiveError ()) >>= (@?= Left ObjectiveDenied)
    ]

fixtureScope :: IO Scope.ObjectiveScope
fixtureScope = do
  session <- genSessionId
  pure (Scope.ObjectiveScope V1 (WorkflowId "scope-codec") (compatibilityIdentity (checked mkAgentName "creator")) session Nothing Nothing (Just []) Nothing (Scope.AgentScope (assignmentIdFor "scope-codec")) Nothing [Scope.InspectObjectives, Scope.ApplyObjectiveCommands, Scope.CreateObjectives] (Just (executionDigestFor "scope-fixture" Aeson.Null)))

identifier :: ObjectiveId
identifier = checked parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q"

checked parser = either (error . show) id . parser

replace field value (Aeson.Object fields) = Aeson.Object (KeyMap.insert field value fields)
replace _ _ value = value

resultEither (Aeson.Error message) = Left message
resultEither (Aeson.Success value) = Right value
