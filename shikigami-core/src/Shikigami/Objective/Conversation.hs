{-# LANGUAGE DataKinds #-}

-- | Objective conversation links. Kioku owns session/turn facts; the objective
-- owner supplies membership checks and the transaction that retains admission.
module Shikigami.Objective.Conversation where

import Contravariant.Extras (contrazip3, contrazip5)
import Data.Aeson qualified as Aeson
import Data.Either (isRight)
import Data.Generics.Labels ()
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelBlueprint (..), runQuery)
import Kioku.Api.Scope (Namespace (..))
import Kioku.Id (SessionId, parseId)
import Kioku.Session.ReadModel qualified as Memory
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Conversation.SessionIndex qualified as Index
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Memory.Scope (shikigamiNamespace)
import Shikigami.Objective.Types
import Shikigami.Prelude

-- The receipt is the binding revision and its immutable objective attribution.
data ConversationBinding = ConversationBinding
  { format :: !(FormatVersion "objective-conversation-binding"),
    conversationId :: !ConversationRef,
    participant :: !AgentIdentity,
    sessionId :: !Text,
    receipt :: !Receipt
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TurnAdmission = TurnAdmission
  { format :: !(FormatVersion "objective-turn-admission"),
    runId :: !RunReference,
    turnId :: !TurnReference,
    conversationId :: !ConversationRef,
    participant :: !AgentIdentity,
    sessionId :: !Text,
    binding :: !(Maybe ConversationBinding)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- The public read-model runner checks registry identity/lifecycle. Its owning
-- query blueprints are then composed into the objective transaction, rather
-- than reproducing Kioku's SQL. This has the runner's own check/query boundary.
checkMemoryModels :: (IOE :> es, Store :> es, Error StoreError :> es) => Eff es (Either ObjectiveError ())
checkMemoryModels = do
  result <- tryError @StoreError checked
  pure (either (const (Left ObjectiveUnavailable)) id result)
  where
    checked = do
      session <- runQuery Nothing Memory.sessionByIdReadModel (Memory.SessionByIdQuery shikigamiMemorySpace "objective-registry-check")
      turns <- runQuery Nothing Memory.turnsBySessionReadModel (Memory.TurnsBySessionQuery shikigamiMemorySpace "objective-registry-check")
      pure (either (const (Left ObjectiveUnavailable)) (const (Right ())) session >> either (const (Left ObjectiveUnavailable)) (const (Right ())) turns)

indexedSession :: ConversationRef -> Tx.Transaction (Either ObjectiveError Memory.SessionRow)
indexedSession conversation = do
  indexed <- Index.lookupConversationSessionTx (conversationRefText conversation)
  case indexed of
    Nothing -> pure (Left ObjectiveMissing)
    Just key -> do
      stored <- Memory.sessionByIdReadModelBlueprint.query (Memory.SessionByIdQuery shikigamiMemorySpace key)
      pure case stored of
        Just row | row.sessionId == key && row.subjectRef == Just (conversationRefText conversation) && isJust (Memory.parseSessionStatus row.status) && isRight (parseId row.sessionId :: Either Text SessionId) && row.namespace == namespace -> Right row
        _ -> Left ObjectiveDenied
  where
    Namespace namespace = shikigamiNamespace

-- Resolve only a recorded member whose identity matches the owning session.
-- An index pointer or a model-authored conversation id cannot invent a member.
participantFor :: Objective -> ConversationRef -> Tx.Transaction (Either ObjectiveError (AgentIdentity, Text))
participantFor objective conversation = do
  stored <- indexedSession conversation
  pure do
    row <- stored
    let matches = [identity | Member {principal = RecordedAgent identity, roles} <- objective.members, not (null roles), identityText identity == Right row.agentId]
    case matches of
      [identity] -> Right (identity, row.sessionId)
      _ -> Left ObjectiveDenied

bindingKey :: ConversationRef -> AgentIdentity -> Text
bindingKey conversation participant = versionedDigest "shikigami.objective-conversation/1" (toJSON (conversation, participant))

lockCoordinate :: Text -> Tx.Transaction ()
lockCoordinate key = Tx.statement key (preparable "SELECT pg_advisory_xact_lock(hashtextextended($1,0))" text D.noResult)

publishBinding :: Objective -> ConversationRef -> Receipt -> Tx.Transaction (Either ObjectiveError ())
publishBinding objective conversation receipt =
  participantFor objective conversation >>= \case
    Left err -> pure (Left err)
    Right (participant, sessionId) -> do
      let binding = ConversationBinding V1 conversation participant sessionId receipt
          key = bindingKey conversation participant
          history = versionedDigest "shikigami.objective-conversation-history/1" (toJSON binding)
          objectiveKey = objectiveIdText receipt.objectiveId
      lockCoordinate key
      Tx.statement key (preparable "DELETE FROM shikigami.objective_associations WHERE kind='conversation-current' AND source_id=$1" text D.noResult)
      Tx.statement (key, objectiveKey, toJSON binding) (insert "conversation-current")
      Tx.statement (history, objectiveKey, toJSON binding) (insert "conversation-history")
      pure (Right ())
  where
    insert kind = preparable ("INSERT INTO shikigami.objective_associations(kind,source_id,objective_id,binding) VALUES ('" <> kind <> "',$1,$2,$3)") (contrazip3 text text json) D.noResult

currentBinding :: ConversationRef -> AgentIdentity -> Tx.Transaction (Either ObjectiveError (Maybe ConversationBinding))
currentBinding conversation participant = do
  let key = bindingKey conversation participant
  values <- Tx.statement key (preparable "SELECT objective_id,binding FROM shikigami.objective_associations WHERE kind='conversation-current' AND source_id=$1 LIMIT 2" text (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))))
  pure case values of
    [] -> Right Nothing
    [(objective, value)] | Aeson.Success binding <- Aeson.fromJSON value, binding.conversationId == conversation, binding.participant == participant, objectiveIdText binding.receipt.objectiveId == objective -> Right (Just binding)
    _ -> Left ObjectiveConflict

-- Retained reads require no mutable index or memory-owner lookup. The caller
-- still checks current objective access before returning a historical snapshot.
lookupTurn :: RunReference -> TurnReference -> ConversationRef -> AgentIdentity -> Tx.Transaction (Either ObjectiveError (Maybe TurnAdmission))
lookupTurn run turn conversation participant = case identityText participant of
  Left _ -> Tx.condemn >> pure (Left ObjectiveDenied)
  Right principal -> do
    saved <- Tx.statement (runReferenceText run, turnReferenceText turn, principal) (preparable "SELECT objective_id,admission FROM shikigami.objective_turn_admissions WHERE run_id=$1 AND turn_id=$2 AND principal_key=$3" (contrazip3 text text text) (D.rowMaybe ((,) <$> D.column (D.nullable D.text) <*> D.column (D.nonNullable D.jsonb))))
    case saved of
      Nothing -> pure (Right Nothing)
      Just (objective, value) -> case Aeson.fromJSON value of
        Aeson.Success admission | admission.runId == run && admission.turnId == turn && admission.conversationId == conversation && admission.participant == participant && objective == (objectiveIdText . (.receipt.objectiveId) <$> admission.binding) -> pure (Right (Just admission))
        _ -> Tx.condemn >> pure (Left ObjectiveConflict)

-- Caller coordinates come from a trusted admitted runtime. The owning memory
-- turn is checked before fresh admission; the recorded snapshot wins on retry,
-- including an explicit absence. The callback checks fresh objective membership.
admitTurn :: (ConversationBinding -> Tx.Transaction (Either ObjectiveError ())) -> RunReference -> TurnReference -> ConversationRef -> AgentIdentity -> Tx.Transaction (Either ObjectiveError TurnAdmission)
admitTurn check run turn conversation participant = do
  let coordinate = versionedDigest "shikigami.objective-turn/1" (toJSON (run, turn, participant))
  lockCoordinate coordinate
  case identityText participant of
    Left _ -> refused ObjectiveDenied
    Right principal -> do
      saved <- lookupTurn run turn conversation participant
      case saved of
        Left err -> refused err
        Right (Just admission) -> authorize admission
        Right Nothing -> do
          session <- indexedSession conversation
          case session of
            Left err -> refused err
            Right row | row.agentId /= principal -> refused ObjectiveDenied
            Right row -> do
              turns <- Memory.turnsBySessionReadModelBlueprint.query (Memory.TurnsBySessionQuery shikigamiMemorySpace row.sessionId)
              if not (any (\owned -> owned.sessionId == row.sessionId && owned.turnId == turnReferenceText turn && owned.role == "user") turns)
                then refused ObjectiveDenied
                else
                  currentBinding conversation participant >>= \case
                    Left err -> refused err
                    Right binding -> do
                      let admission = TurnAdmission V1 run turn conversation participant row.sessionId binding
                      allowed <- authorize admission
                      case allowed of
                        Left err -> refused err
                        Right _ -> do
                          -- Check the objective before locking the binding,
                          -- matching publication's lock order. A concurrent
                          -- rebind produces a visible conflict before any write.
                          lockCoordinate (bindingKey conversation participant)
                          latest <- currentBinding conversation participant
                          if latest /= Right binding
                            then refused ObjectiveConflict
                            else do
                              Tx.statement (runReferenceText run, turnReferenceText turn, principal, objectiveIdText . (.receipt.objectiveId) <$> binding, toJSON admission) (preparable "INSERT INTO shikigami.objective_turn_admissions(run_id,turn_id,principal_key,objective_id,admission) VALUES ($1,$2,$3,$4,$5)" (contrazip5 text text text (E.param (E.nullable E.text)) json) D.noResult)
                              pure (Right admission)
  where
    authorize admission = case admission.binding of
      Nothing -> pure (Right admission)
      Just binding | binding.conversationId /= conversation || binding.participant /= participant -> refused ObjectiveConflict
      Just binding -> check binding >>= either refused (const (pure (Right admission)))
    refused err = Tx.condemn >> pure (Left err)

text :: E.Params Text
text = E.param (E.nonNullable E.text)

json :: E.Params Aeson.Value
json = E.param (E.nonNullable E.jsonb)
