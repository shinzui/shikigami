-- | Private projection of accepted manifests, committed with the objective.
-- Protected reads are exposed only by the authenticated checkpoint adapter.
module Shikigami.Coordination.Sql (saveDecision, readDecision, readArrangement) where

import Contravariant.Extras (contrazip2, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Coordination.Proposal
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Types
import Shikigami.Prelude

saveDecision :: AcceptedDecision -> Receipt -> Transaction ()
saveDecision decision receipt =
  Tx.statement
    (objectiveIdText receipt.objectiveId, operationIdText receipt.operationId, revisionNumber receipt.revision, toJSON decision)
    (preparable "INSERT INTO shikigami.adaptive_decisions (objective_id,operation_id,revision,manifest) VALUES ($1,$2,$3,$4)" (contrazip4 text text (fromInteger >$< E.param (E.nonNullable E.numeric)) json) D.noResult)
  where
    text = E.param (E.nonNullable E.text)
    json = E.param (E.nonNullable E.jsonb)

readDecision :: ObjectiveId -> OperationId -> Transaction (Either ObjectiveError (Maybe AcceptedDecision))
readDecision objective operation =
  fmap
    ( \value -> do
        decoded <- decode value
        forM_ decoded \decision -> unless (decision.proposal.objectiveId == objective && decision.proposal.operationId == operation) (Left ObjectiveUnavailable)
        pure decoded
    )
    $ Tx.statement
      (objectiveIdText objective, operationIdText operation)
      (preparable "SELECT manifest FROM shikigami.adaptive_decisions WHERE objective_id=$1 AND operation_id=$2" (contrazip2 text text) (D.rowMaybe (D.column (D.nonNullable D.jsonb))))
  where
    text = E.param (E.nonNullable E.text)

readArrangement :: ObjectiveId -> Transaction (Either ObjectiveError (Maybe [Placement]))
readArrangement objective =
  fmap
    ( \value -> do
        decoded <- decode value
        forM_ decoded \decision -> unless (decision.proposal.objectiveId == objective) (Left ObjectiveUnavailable)
        pure ((.arrangement) <$> decoded)
    )
    $ Tx.statement
      (objectiveIdText objective)
      (preparable "SELECT manifest FROM shikigami.adaptive_decisions WHERE objective_id=$1 ORDER BY revision DESC LIMIT 1" (E.param (E.nonNullable E.text)) (D.rowMaybe (D.column (D.nonNullable D.jsonb))))

decode :: Maybe Aeson.Value -> Either ObjectiveError (Maybe AcceptedDecision)
decode = traverse \value -> case Aeson.fromJSON value of
  Aeson.Success decision | decision.format == V1 && decision.validatorVersion == "shikigami.adaptive-validator/1" -> Right decision
  Aeson.Success _ -> Left ObjectiveUnavailable
  Aeson.Error _ -> Left ObjectiveUnavailable
