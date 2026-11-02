{-# LANGUAGE DataKinds #-}

-- | Protected admission metadata, retained by the execution snapshot or the
-- Flow journal. A decoded selector is never an executable authority grant.
module Shikigami.Objective.Scope where

import Data.Aeson ((.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kioku.Id (SessionId)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.AssignmentKey (AssignmentKey, conversationAssignmentIdFor)
import Shikigami.Execution.Coordinate (ExecutionDigest, executionDigestFor)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Generated.Nominals (ObjectiveId)
import Shikigami.Objective.Keys (ConversationRef, TurnReference, turnReferenceText)
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision (StateRevision)

-- These coordinates come from the owning workflow and accepted assignment.
data ScopeSource
  = AgentScope !AssignmentKey
  | ConversationScope !AssignmentKey !ConversationRef !TurnReference
  | FlowScope !WorkflowName !(StateRevision "objective-scope-generation")
  deriving stock (Eq, Show, Generic)

instance ToJSON ScopeSource where
  toJSON = \case
    AgentScope assignment -> Aeson.object ["tag" .= ("agent" :: Text), "assignment" .= assignment]
    ConversationScope assignment conversation turn -> Aeson.object ["tag" .= ("conversation" :: Text), "assignment" .= assignment, "conversation" .= conversation, "turn" .= turn]
    FlowScope (WorkflowName name) generation -> Aeson.object ["tag" .= ("flow" :: Text), "name" .= name, "generation" .= generation]

instance FromJSON ScopeSource where
  parseJSON = Aeson.withObject "objective scope source" \fields -> do
    tag <- fields .: "tag"
    case tag :: Text of
      "agent" -> keys ["tag", "assignment"] fields >> AgentScope <$> fields .: "assignment"
      "conversation" -> keys ["tag", "assignment", "conversation", "turn"] fields >> ConversationScope <$> fields .: "assignment" <*> fields .: "conversation" <*> fields .: "turn"
      "flow" -> keys ["tag", "name", "generation"] fields >> FlowScope <$> (WorkflowName <$> fields .: "name") <*> fields .: "generation"
      _ -> fail "unknown objective scope source"
    where
      keys allowed fields = unless (all (`elem` allowed) (KeyMap.keys fields)) (fail "unknown source field")

data ScopePermission = InspectObjectives | ApplyObjectiveCommands | CreateObjectives
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectiveScope = ObjectiveScope
  { format :: !(FormatVersion "objective-scope"),
    runId :: !WorkflowId,
    identity :: !AgentIdentity,
    sessionId :: !SessionId,
    rootId :: !(Maybe ExecutionRootId),
    cutoff :: !(Maybe UTCTime),
    permittedAliases :: !(Maybe [ModelAlias]),
    target :: !(Maybe ObjectiveId),
    source :: !ScopeSource,
    coordination :: !(Maybe (ExecutionDigest "coordination-scope")),
    permissions :: ![ScopePermission],
    creationPolicy :: !(Maybe (ExecutionDigest "objective-creation-policy"))
  }
  deriving stock (Eq, Generic)

instance Show ObjectiveScope where show _ = "ObjectiveScope <protected>"

instance ToJSON ObjectiveScope where
  toJSON scope = Aeson.object ["format" .= scope.format, "runId" .= scope.runId.unWorkflowId, "identity" .= scope.identity, "sessionId" .= scope.sessionId, "rootId" .= scope.rootId, "cutoff" .= scope.cutoff, "permittedAliases" .= scope.permittedAliases, "target" .= scope.target, "source" .= scope.source, "coordination" .= scope.coordination, "permissions" .= scope.permissions, "creationPolicy" .= scope.creationPolicy]

instance FromJSON ObjectiveScope where
  parseJSON = Aeson.withObject "objective scope" \fields -> do
    unless (all (`elem` ["format", "runId", "identity", "sessionId", "rootId", "cutoff", "permittedAliases", "target", "source", "coordination", "permissions", "creationPolicy"]) (KeyMap.keys fields)) (fail "unknown objective scope field")
    scope <- ObjectiveScope <$> fields .: "format" <*> (WorkflowId <$> fields .: "runId") <*> fields .: "identity" <*> fields .: "sessionId" <*> fields .:? "rootId" <*> fields .:? "cutoff" <*> fields .:? "permittedAliases" <*> fields .:? "target" <*> fields .: "source" <*> fields .:? "coordination" <*> fields .: "permissions" <*> fields .:? "creationPolicy"
    unless (validScope scope) (fail "invalid objective scope")
    pure scope

validScope :: ObjectiveScope -> Bool
validScope scope = scope.format == V1 && isJust scope.rootId == isJust scope.cutoff && validSource scope.source && (isNothing scope.coordination || isJust scope.target) && either (const False) (const True) (identityText scope.identity) && not (Text.null scope.runId.unWorkflowId) && (isJust scope.target || isJust scope.creationPolicy) && scope.permissions == nub scope.permissions && InspectObjectives `elem` scope.permissions && ApplyObjectiveCommands `elem` scope.permissions && (CreateObjectives `elem` scope.permissions) == isJust scope.creationPolicy

scopeFingerprint :: ObjectiveScope -> ExecutionDigest "objective-scope"
scopeFingerprint = executionDigestFor "shikigami.objective-scope/1" . toJSON

matchesExecution :: ObjectiveScope -> WorkflowId -> AgentIdentity -> SessionId -> Maybe ExecutionRootId -> [ModelAlias] -> AssignmentKey -> Bool
matchesExecution scope run identity session root aliases assignment =
  validScope scope && scope.runId == run && scope.identity == identity && scope.sessionId == session && scope.rootId == root && scope.permittedAliases == Just aliases && case scope.source of
    AgentScope bound -> bound == assignment
    ConversationScope bound _ turn -> bound == assignment && maybe False (\message -> not (Text.null message) && bound == conversationAssignmentIdFor run.unWorkflowId message) (Text.stripPrefix "danwa:user:" (turnReferenceText turn))
    FlowScope {} -> False

validSource :: ScopeSource -> Bool
validSource = \case
  AgentScope _ -> True
  ConversationScope _ _ turn -> maybe False (not . Text.null) (Text.stripPrefix "danwa:user:" (turnReferenceText turn))
  FlowScope (WorkflowName name) _ -> not (Text.null name)
