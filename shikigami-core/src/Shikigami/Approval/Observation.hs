-- | Approval-owner parent links. Publication belongs to the trusted approval
-- producer; readers never reconstruct links by guessing review request keys or
-- loading child results. This metadata is not a workflow command or a grant.
module Shikigami.Approval.Observation
  ( ApprovalAssociation (..),
    ApprovalObservationError (..),
    recordApprovalAssociationTx,
    observeApprovalAssociations,
  )
where

import Contravariant.Extras (contrazip3)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Shikigami.Agent.Approval (ReviewRequestId, reviewRequestIdText)

data ApprovalAssociation = ApprovalAssociation
  { review :: !ReviewRequestId,
    parentName :: !Text,
    parentId :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ApprovalAssociation where
  toJSON value = object ["review" .= value.review, "parentName" .= value.parentName, "parentId" .= value.parentId]

instance FromJSON ApprovalAssociation where
  parseJSON = withObject "ApprovalAssociation" \fields -> do
    value <- ApprovalAssociation <$> fields .: "review" <*> fields .: "parentName" <*> fields .: "parentId"
    unless (valid value.parentName && valid value.parentId) (fail "invalid approval parent coordinate")
    pure value

valid :: Text -> Bool
valid value = not (Text.null value) && Text.length value <= 512

data ApprovalObservationError = ApprovalAssociationConflict | ApprovalMetadataCorrupt | ApprovalObservationBound
  deriving stock (Eq, Show)

-- | Compose with the owner's retained approval admission. Replaying an exact
-- parent binding converges; another parent cannot reinterpret that approval.
recordApprovalAssociationTx :: ReviewRequestId -> WorkflowName -> WorkflowId -> Transaction (Either ApprovalObservationError ())
recordApprovalAssociationTx review (WorkflowName name) (WorkflowId identifier)
  | not (valid name && valid identifier) = Tx.condemn >> pure (Left ApprovalMetadataCorrupt)
  | otherwise = do
      Tx.statement
        (reviewRequestIdText review, name, identifier)
        (preparable "INSERT INTO shikigami.approval_observation_associations(review_id,parent_name,parent_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 text text text) D.noResult)
      saved <-
        Tx.statement
          (reviewRequestIdText review)
          (preparable "SELECT parent_name,parent_id FROM shikigami.approval_observation_associations WHERE review_id=$1" text (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text))))
      if saved == Just (name, identifier) then pure (Right ()) else Tx.condemn >> pure (Left ApprovalAssociationConflict)
  where
    text = E.param (E.nonNullable E.text)

-- | Bounded exact-parent join. Missing links remain unknown; a timer with no
-- link is not evidence that a parent is awaiting approval.
observeApprovalAssociations :: NonEmpty (WorkflowName, WorkflowId) -> Transaction (Either ApprovalObservationError [ApprovalAssociation])
observeApprovalAssociations parents
  | NonEmpty.length parents > 256 = pure (Left ApprovalObservationBound)
  | otherwise = do
      let coordinates = map (\(WorkflowName name, WorkflowId identifier) -> object ["name" .= name, "id" .= identifier]) (NonEmpty.toList parents)
      rows <-
        Tx.statement
          (toJSON coordinates)
          (preparable "SELECT jsonb_build_object('review',a.review_id,'parentName',a.parent_name,'parentId',a.parent_id) FROM shikigami.approval_observation_associations a JOIN jsonb_array_elements($1) p ON a.parent_name=p->>'name' AND a.parent_id=p->>'id' ORDER BY a.review_id LIMIT 257" (E.param (E.nonNullable E.jsonb)) (D.rowList (D.column (D.nonNullable D.jsonb))))
      pure if length rows > 256 then Left ApprovalObservationBound else traverse decode rows
  where
    decode value = case Aeson.fromJSON value of Aeson.Success association -> Right association; _ -> Left ApprovalMetadataCorrupt
