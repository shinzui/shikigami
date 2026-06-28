module Shikigami.Flow.Acknowledgement
  ( Ack (..),
    ackFromDecision,
    awaitAcknowledgement,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Keiro.Workflow (StepName, Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Approval qualified as Approval

data Ack
  = Acknowledged !Value
  | Declined !Text
  | TimedOut
  deriving stock (Eq, Show)

awaitAcknowledgement ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Approval.ApprovalEnv ->
  StepName ->
  Approval.ApprovalRequest ->
  NominalDiffTime ->
  Eff es Ack
awaitAcknowledgement env name req deadline =
  ackFromDecision <$> Approval.awaitApproval env name req (Just deadline)

ackFromDecision :: Approval.ApprovalDecision -> Ack
ackFromDecision = \case
  Approval.Approved value -> Acknowledged value
  Approval.Rejected reason -> Declined reason
  Approval.TimedOut -> TimedOut
