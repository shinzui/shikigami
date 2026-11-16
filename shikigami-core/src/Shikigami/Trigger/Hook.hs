-- | What a flow pack contributes to trigger intake (docs/adr/0129).
--
-- A stream record that matches an agent's trigger normally becomes one run
-- job. A pack whose flow /observes/ a stream wants more say: most observed
-- records are not worth a run, and the ones that are must run under a bounded
-- evaluation envelope. The pack decides; the kernel commits.
--
-- The split keeps the durable guarantee where it was. The consumer commits
-- exactly one effect per record in its inbox transaction, so a hook answers
-- with data and with 'Transaction' actions the consumer runs there. A hook
-- never opens a transaction, allocates a root or enqueues a job: allocating
-- the evaluation root and enqueueing its run are kernel resource and queue
-- code, and stay in the kernel.
module Shikigami.Trigger.Hook
  ( TriggerHooks (..),
    noTriggerHooks,
    StreamHook (..),
    StreamCandidate (..),
    StreamDisposition (..),
    StreamSkip (..),
    StreamEvaluation (..),
    StreamIntake,
    PackDisposition (..),
    noStreamIntake,
    streamIntake,
    ScheduleHook (..),
    ScheduleCandidate (..),
    ScheduledAllowance (..),
    ScheduleIntake,
    PackAllowance (..),
    noScheduleIntake,
    scheduleIntake,
  )
where

import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime)
import Hasql.Transaction (Transaction)
import Keiro.Workflow (WorkflowId)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Principal (AgentIdentity, AgentPrincipal)
import Shikigami.Execution.Resources (Envelope, Limits)
import Shikigami.Pack.Setting (PackSettings)

-- | The trigger hooks one pack contributes. A field arrives with its first
-- consumer (ADR-1).
data TriggerHooks = TriggerHooks
  { stream :: !(Maybe StreamHook),
    schedule :: !(Maybe ScheduleHook)
  }

noTriggerHooks :: TriggerHooks
noTriggerHooks = TriggerHooks {stream = Nothing, schedule = Nothing}

-- | A pack's say over the stream records that match its flows' agents. Pure
-- and total: the two instants are the consumer's, and no clock is read.
newtype StreamHook = StreamHook (PackSettings -> StreamCandidate -> StreamDisposition)

-- | One matched record, after the directory admitted the agent's identity.
data StreamCandidate = StreamCandidate
  { activity :: !ActivityEnvelope,
    agent :: !AgentDecl,
    -- | The identity the run job would carry.
    identity :: !AgentIdentity,
    -- | The record's resolved occurrence instant.
    occurredAt :: !UTCTime,
    -- | When the consumer received it; it fixes an evaluation's cutoff.
    receivedAt :: !UTCTime
  }

data StreamDisposition
  = -- | The pack does not observe for this identity. The record takes the
    -- ordinary trigger path, with the job bytes it would have had.
    StreamOrdinary
  | -- | Not worth a run. One bounded record, and nothing is enqueued.
    StreamSkipped !StreamSkip
  | -- | Worth one evaluation under a root with this envelope.
    StreamEvaluated !StreamEvaluation

data StreamSkip = StreamSkip
  { -- | A bounded tag for logs and metrics, never observed text.
    reason :: !Text,
    -- | The pack's record of the skip, run in the consumer's inbox transaction.
    record :: !(Transaction ())
  }

data StreamEvaluation = StreamEvaluation
  { -- | The limits and cutoff of the evaluation root the kernel allocates.
    envelope :: !Envelope,
    -- | Whether the pack already holds this observation, delivered earlier
    -- under another message id. If so the run it funded is already owned and
    -- nothing more is committed.
    alreadyOwned :: !(Transaction Bool),
    -- | The pack's record of the candidate, bound to the run that evaluates it.
    record :: !(WorkflowId -> Transaction ())
  }

-- | What the consumer asks for each matched record: the owning pack's name,
-- for logs and metrics, and its disposition.
data PackDisposition = PackDisposition
  { pack :: !Text,
    disposition :: !StreamDisposition
  }

-- | The composed hooks, as the consumer consults them. 'Nothing' means no
-- pack has a say over this agent.
type StreamIntake = StreamCandidate -> Maybe PackDisposition

-- | No pack observes: every matched record takes the ordinary path.
noStreamIntake :: StreamIntake
noStreamIntake = const Nothing

-- | One pack's hook as an intake, for the agents that pack owns.
streamIntake :: Text -> (AgentDecl -> Bool) -> PackSettings -> StreamHook -> StreamIntake
streamIntake pack owns settings (StreamHook decide) candidate
  | owns candidate.agent = Just PackDisposition {pack, disposition = decide settings candidate}
  | otherwise = Nothing

-- | A pack's say over the scheduled ticks of its flows' agents (ADR-119).
--
-- A scheduled run normally starts with no resource root. A pack whose flow
-- spends on a schedule, with nobody there to fund it, declares an operator
-- owned allowance instead: the tick enrolls a fresh root with those limits and
-- binds it to the run, in the transaction that enqueues the job. The pack
-- supplies only the allowance check. Recovering the root and binding it are
-- kernel resource code ("Shikigami.Trigger.Enrollment").
--
-- Pure and total. 'Left' refuses the tick with a bounded reason, recorded as
-- a run skip; @Right Nothing@ lets the tick run without a root.
newtype ScheduleHook = ScheduleHook (PackSettings -> ScheduleCandidate -> Either Text (Maybe ScheduledAllowance))

-- | One due tick, after the directory admitted the agent's identity.
data ScheduleCandidate = ScheduleCandidate
  { agent :: !AgentDecl,
    -- | The identity the run job would carry.
    identity :: !AgentIdentity,
    dueAt :: !UTCTime
  }

-- | What an enrolled tick may spend, and who may spend it.
data ScheduledAllowance = ScheduledAllowance
  { -- | The only principal the root is enrolled for.
    principal :: !AgentPrincipal,
    limits :: !Limits,
    -- | How long after the tick fires the root's cutoff falls.
    lifetime :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

-- | The owning pack's answer for one tick, with its name for logs.
data PackAllowance = PackAllowance
  { pack :: !Text,
    allowance :: !(Either Text (Maybe ScheduledAllowance))
  }

-- | The composed hooks, as the scheduler consults them. 'Nothing' means no
-- pack has a say over this agent, and the tick runs without a root.
type ScheduleIntake = ScheduleCandidate -> Maybe PackAllowance

noScheduleIntake :: ScheduleIntake
noScheduleIntake = const Nothing

-- | One pack's hook as an intake, for the agents that pack owns.
scheduleIntake :: Text -> (AgentDecl -> Bool) -> PackSettings -> ScheduleHook -> ScheduleIntake
scheduleIntake pack owns settings (ScheduleHook decide) candidate
  | owns candidate.agent = Just PackAllowance {pack, allowance = decide settings candidate}
  | otherwise = Nothing
