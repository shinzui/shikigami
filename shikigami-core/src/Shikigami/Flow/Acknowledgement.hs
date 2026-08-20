{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Acknowledgement
  ( Ack (..),
    Acknowledgement,
    ackFromDecision,
    awaitAck,
    awaitAcknowledgement,
    runAcknowledgement,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (StepName, Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Approval qualified as Approval

data Ack
  = Acknowledged !Value
  | Declined !Text
  | TimedOut
  deriving stock (Eq, Show)

-- | Park a flow until a human answers, or until the deadline does.
--
-- This exists as a capability rather than a direct call so that a flow body can
-- park without holding 'Store' or 'IOE'. Those two were the last ambient
-- effects in 'Shikigami.Flow.FlowEffects', and while a flow could reach them it
-- could also reach any un-journaled IO it liked — which is precisely what makes
-- a durable workflow replay incorrectly. 'awaitAcknowledgement' still needs
-- them; the point is that the interpreter holds them and the flow does not.
--
-- The environment and the deadline move out of the flow body for the same
-- reason: they are deployment configuration, not a decision the flow makes, and
-- a body that closed over them needed constructing per-run.
data Acknowledgement :: Effect where
  AwaitAcknowledgement :: StepName -> Approval.ApprovalRequest -> Acknowledgement m Ack

type instance DispatchOf Acknowledgement = Dynamic

-- | Park under @name@ until the request is answered.
--
-- @name@ is a journal step label with the same durability the memory and sink
-- labels have: it identifies the park in the workflow journal, so renaming one
-- is a durable-contract change governed by @docs\/workflow-versioning.md@. The
-- at-risk flow's @await-ack@ is declared in @domain\/shikigami-agent-run.keiro@.
awaitAck :: (Acknowledgement :> es) => StepName -> Approval.ApprovalRequest -> Eff es Ack
awaitAck name req = send (AwaitAcknowledgement name req)

-- | Interpret 'Acknowledgement' against the approval machinery.
--
-- This is where 'Store' and 'IOE' live now. 'Approval.awaitApproval' allocates
-- an awakeable and arms a durable deadline timer, both of which need them.
runAcknowledgement ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Approval.ApprovalEnv ->
  NominalDiffTime ->
  Eff (Acknowledgement : es) a ->
  Eff es a
runAcknowledgement env deadline =
  interpret \_ -> \case
    AwaitAcknowledgement name req -> awaitAcknowledgement env name req deadline

-- | The direct call the capability wraps. Still exported because
-- 'runAcknowledgement' is not the only possible caller and because the
-- lifecycle tests exercise the mapping below without a workflow.
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
