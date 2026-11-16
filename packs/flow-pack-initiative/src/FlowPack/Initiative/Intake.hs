-- | The one call intake makes for a matched agent: allowance, adapter and
-- pre-filter composed into one bounded disposition.
module FlowPack.Initiative.Intake
  ( Disposition (..),
    disposition,
    streamDisposition,
  )
where

import Data.Time (UTCTime)
import FlowPack.Initiative.Ledger qualified as Ledger
import FlowPack.Initiative.Prefilter (prefilter)
import FlowPack.Initiative.Settings
import FlowPack.Initiative.Source (observe)
import FlowPack.Initiative.Types
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Resources (Envelope)
import Shikigami.Pack.Sdk (StreamCandidate (..), StreamDisposition (..), StreamEvaluation (..), StreamSkip (..))

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

-- | 'disposition' as the kernel's stream hook answers it: the same verdict,
-- with the ledger transactions the consumer commits for it.
streamDisposition :: Maybe InitiativeSettings -> StreamCandidate -> StreamDisposition
streamDisposition settings candidate =
  case disposition settings candidate.occurredAt candidate.receivedAt candidate.identity candidate.activity of
    NotObserving -> StreamOrdinary
    SkipEnvelope allowance reason -> skipped allowance (Left (reason, candidate.activity.activityId))
    SkipObserved allowance reason observed -> skipped allowance (Right (reason, observed))
    Evaluate _ worthwhile envelope ->
      let facts = candidateFacts worthwhile
       in StreamEvaluated
            StreamEvaluation
              { envelope,
                alreadyOwned = Ledger.candidateRecordedTx facts.observer facts.observed.activity,
                record = \workflow -> Ledger.recordCandidateTx worthwhile workflow candidate.receivedAt
              }
  where
    skipped allowance skip =
      StreamSkipped
        StreamSkip
          { reason = skipReasonText (either fst fst skip),
            record = Ledger.recordSkipTx allowance.principal candidate.receivedAt Nothing skip
          }
