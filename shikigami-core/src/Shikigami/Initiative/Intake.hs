-- | The one call intake makes for a matched agent: allowance, adapter and
-- pre-filter composed into one bounded disposition.
module Shikigami.Initiative.Intake
  ( Disposition (..),
    disposition,
  )
where

import Data.Time (UTCTime)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Resources (Envelope)
import Shikigami.Initiative.Prefilter (prefilter)
import Shikigami.Initiative.Settings
import Shikigami.Initiative.Source (observe)
import Shikigami.Initiative.Types

data Disposition
  = -- | No settings, or no allowance for this identity: the agent is not an
    -- observer and takes the ordinary trigger path, byte for byte.
    NotObserving
  | -- | The envelope could not be observed at all; recorded without a subject.
    SkipEnvelope !ObserverAllowance !SkipReason
  | -- | Observed, then refused by the pre-filter.
    SkipObserved !ObserverAllowance !SkipReason !Observed
  | -- | Worth one evaluation under this root envelope.
    Evaluate !ObserverAllowance !Candidate !Envelope
  deriving stock (Eq, Show)

-- | Total and pure. The occurrence instant is the caller's resolved one and
-- @receivedAt@ fixes the evaluation root's cutoff; neither is read from a clock.
disposition :: Maybe InitiativeSettings -> UTCTime -> UTCTime -> AgentIdentity -> ActivityEnvelope -> Disposition
disposition settings occurredAt receivedAt identity envelope = case settings of
  Nothing -> NotObserving
  Just configured -> case resolveAllowance configured identity of
    Left _ -> NotObserving
    Right allowance -> case observe occurredAt envelope of
      Left reason -> SkipEnvelope allowance reason
      Right observed -> case prefilter allowance observed of
        Left reason -> SkipObserved allowance reason observed
        Right candidate -> Evaluate allowance candidate (evaluationEnvelopeAt receivedAt allowance.evaluation)
