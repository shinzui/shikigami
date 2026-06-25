-- | The IP-7 trigger→run contract: a fired trigger becomes a 'RunJob' on the
-- @shikigami_run_jobs@ pgmq queue, which the worker (EP-5) drains. Client-safe (no
-- hasql/effectful deps) so the enqueuer and the worker share it.
module Shikigami.Api.RunJob
  ( TriggerKind (..),
    RunJob (..),
  )
where

import Data.Aeson (Value)
import Shikigami.Prelude

-- | Which trigger class produced the job.
data TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A request to run one declared agent, with the trigger occurrence and payload.
data RunJob = RunJob
  { agentName :: !Text,
    triggerKind :: !TriggerKind,
    occurredAt :: !UTCTime,
    triggerPayload :: !Value,
    idempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
