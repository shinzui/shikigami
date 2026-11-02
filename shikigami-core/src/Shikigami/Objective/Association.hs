-- | Trusted run admission, composed inside the ledger's acceptance transaction.
-- No association is inferred from trigger JSON.
module Shikigami.Objective.Association
  ( RunAdmission (..),
    admitRunTx,
    lookupRunTx,
    ConversationBinding (..),
    TurnAdmission (..),
    module Shikigami.Objective.Origin,
  )
where

import Contravariant.Extras (contrazip3)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.List (find)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Conversation (ConversationBinding (..), TurnAdmission (..))
import Shikigami.Objective.Origin
import Shikigami.Objective.Reference
import Shikigami.Objective.Store qualified as Store
import Shikigami.Objective.Types
import Shikigami.Prelude

data RunAdmission = NewRun | RetainedRun
  deriving stock (Eq, Show)

-- | The adapter supplies a verified caller, never a principal parsed from input.
-- Current membership and assignment ownership are checked under the objective
-- lock shared by revocation. A refusal condemns even a caller that ignores it.
admitRunTx :: RunAdmission -> ObjectiveSettings -> AccessPrincipal -> AgentIdentity -> WorkflowId -> ObjectiveAssociation -> Tx.Transaction (Either Text ())
admitRunTx admission settings actor identity run reference = do
  stored <- Tx.statement (objectiveIdText reference.objectiveId) select
  now <- Tx.statement () (preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz))))
  case stored of
    Just value
      | Aeson.Success current <- Aeson.fromJSON value,
        Right () <- Store.validateSnapshot current,
        current.objectiveId == reference.objectiveId,
        Store.mayCoordinate (Access actor settings now [] Nothing) current,
        admission == RetainedRun || current.status `elem` [Open, Blocked],
        Just assignment <- find ((== reference.assignmentId) . (.definition.assignmentId)) current.assignments,
        admission == RetainedRun || assignment.definition.owner == identity,
        admission == RetainedRun || assignment.definition.state /= Withdrawn,
        admission == RetainedRun || any (\member -> member.principal == RecordedAgent identity && any (`elem` member.roles) [Owner, Coordinator, Worker]) current.members -> do
          when (admission == NewRun) (Tx.statement (run.unWorkflowId, objectiveIdText reference.objectiveId, toJSON reference) insert)
          pure (Right ())
    _ -> Tx.condemn >> pure (Left "The objective association is unavailable or unauthorized.")
  where
    select = preparable "SELECT state FROM shikigami.objectives WHERE objective_id=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.rowMaybe (D.column (D.nonNullable D.jsonb)))
    insert = preparable "INSERT INTO shikigami.objective_associations(kind,source_id,objective_id,binding) VALUES ('run',$1,$2,$3) ON CONFLICT (kind,source_id,objective_id) DO NOTHING" (contrazip3 text text (E.param (E.nonNullable E.jsonb))) D.noResult
    text = E.param (E.nonNullable E.text)

-- | Internal owning-store lookup; public reads still require current membership.
lookupRunTx :: WorkflowId -> Tx.Transaction (Either Text (Maybe ObjectiveAssociation))
lookupRunTx run = do
  rows <- Tx.statement run (preparable "SELECT objective_id,binding FROM shikigami.objective_associations WHERE kind='run' AND source_id=$1 LIMIT 2" ((.unWorkflowId) >$< E.param (E.nonNullable E.text)) (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))))
  case rows of
    [] -> pure (Right Nothing)
    [(objective, value)] | Aeson.Success reference <- Aeson.fromJSON value, objective == objectiveIdText reference.objectiveId -> pure (Right (Just reference))
    _ -> Tx.condemn >> pure (Left "The retained objective association is corrupt.")
