{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Capability
  ( Activity,
    Memory,
    MemoryEnv (..),
    MemoryQuery (..),
    Sink,
    SinkEnv (..),
    currentActivity,
    emitSignal,
    recall,
    remember,
    runActivity,
    runMemory,
    runSink,
  )
where

import Data.Aeson (Value)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, patch)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.App (AppEnv, runAppIO)
import Kioku.Id (MemoryId, SessionId, genMemoryId)
import Kioku.Memory qualified as MemoryStore
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kiroku.Store.Effect (Store)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), MemoryPolicy (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Run (behaviorKindText, recallPriorLearnings, renderLearning)
import Shikigami.Flow.SinkOutbox (enqueueSinkIntentStep)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Sink (GrantSource)
import Shikigami.Sink.Recipient (resolveSinkRecipient)
import Shikigami.Sink.Types (DanwaTarget, SinkResult)

newtype MemoryQuery = MemoryQuery {query :: Text}
  deriving stock (Eq, Show)

data MemoryEnv = MemoryEnv
  { appEnv :: !AppEnv,
    agent :: !AgentDecl,
    sessionId :: !(Maybe SessionId)
  }

data SinkEnv = SinkEnv
  { agent :: !Text,
    runId :: !Text,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    -- | The activity that triggered the flow, carried so a @KizashiSignal@
    -- emitted from inside it can resolve @recipientFrom = Actor@ the same way
    -- the plain agent path does. A flow with no triggering activity simply
    -- resolves nothing and falls back to the declaration's default.
    activity :: !(Maybe ActivityEnvelope),
    -- | Which grant source the enqueue-time C11 check consults for sinks emitted
    -- from inside a flow.
    grants :: !GrantSource
  }

data Memory :: Effect where
  Recall :: MemoryQuery -> Memory m [MemoryRecord]
  Remember :: Value -> Memory m MemoryId

type instance DispatchOf Memory = Dynamic

data Sink :: Effect where
  EmitSignal :: Text -> Agent.Sink -> Value -> Sink m SinkResult

type instance DispatchOf Sink = Dynamic

data Activity :: Effect where
  CurrentActivity :: Activity m ActivityEnvelope

type instance DispatchOf Activity = Dynamic

recall :: (Memory :> es) => MemoryQuery -> Eff es [MemoryRecord]
recall query' = send (Recall query')

remember :: (Memory :> es) => Value -> Eff es MemoryId
remember value = send (Remember value)

-- | Emit a signal through a declared sink, journaling it under a step name
-- derived from @label@.
--
-- @label@ is a caller-supplied stable token: short, lowercase, unique among the
-- emissions of one flow, and never derived from data that varies between a run
-- and its replays. It is the emission's durable identity — the journal step name
-- and, through it, the outbox message id — so renaming one is a durable-contract
-- change governed by @docs\/workflow-versioning.md@. Values that are themselves
-- replay-stable (a ticket id read out of a journaled verdict) are permissible
-- but discouraged; prefer a static token.
emitSignal :: (Sink :> es) => Text -> Agent.Sink -> Value -> Eff es SinkResult
emitSignal label sink output = send (EmitSignal label sink output)

currentActivity :: (Activity :> es) => Eff es ActivityEnvelope
currentActivity = send CurrentActivity

runMemory :: (IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
runMemory MemoryEnv {appEnv, agent = decl@AgentDecl {memory = MemoryPolicy {recallLimit}}, sessionId} =
  interpret \_ -> \case
    Recall MemoryQuery {query} ->
      liftIO (recallPriorLearnings appEnv recallLimit (agentScope (name decl)) query)
    Remember value -> liftIO do
      mid <- genMemoryId
      recordedAt <- getCurrentTime
      let focus = behaviorKindText (behavior decl)
          record =
            RecordMemoryData
              { memoryId = mid,
                memorySpaceId = shikigamiMemorySpace,
                actorPrincipal = agentActor (name decl),
                ownerPrincipal = Nothing,
                agentId = name decl,
                sessionId,
                scope = agentScope (name decl),
                memoryType = MemoryPattern,
                content = renderLearning value,
                priority = 100,
                confidence = MediumConfidence,
                tags = Set.fromList ["flow", focus],
                supersedes = Nothing,
                recordedAt
              }
      runAppIO appEnv (MemoryStore.record record) >>= \case
        Right (Right stored) -> pure stored
        Right (Left err) -> ioError (userError ("failed to record flow memory: " <> show err))
        Left err -> ioError (userError ("failed to record flow memory: " <> show err))

-- | Interpret 'Sink' by enqueueing each emission as a journaled outbox intent.
--
-- The step name an emission journals under is its durable identity, and this
-- interpreter chooses between two schemes for it. The scheme is decided once per
-- interpreted run by a keiro patch, not per emission, because the choice must be
-- the same for every emission of one flow instance.
--
-- Before the patch, the name came from a per-run counter — @emit-signal:0@,
-- @emit-signal:1@ — which is stable only while the flow code is frozen. A deploy
-- that inserted, removed, or reordered an emission shifted every later ordinal,
-- so a flow parked between two emissions would resume and replay the /wrong/
-- recorded result under a name that had moved, while the emission whose name
-- moved away re-enqueued under a fresh outbox id: a silently wrong signal and a
-- duplicate one.
--
-- 'patch' is what keeps both populations correct from one body. A flow already in
-- flight when this shipped has no recorded patch set, so @useLabels@ is 'False'
-- and it keeps the ordinal scheme its journal was written under. A flow started
-- afterwards records the set, takes 'True', and uses the caller's stable label
-- for good. Delete the 'False' branch and the patch id together, and only once no
-- pre-change flow can still resume; see @docs\/workflow-versioning.md@.
--
-- The @ordinal@ carried /inside/ the 'SinkIntent' payload keeps its meaning — the
-- position of the emission — in both branches. Only the journal step name, and
-- with it the deterministic outbox id, differ.
runSink :: (Workflow :> es, Store :> es, IOE :> es) => SinkEnv -> Eff (Sink : es) a -> Eff es a
runSink SinkEnv {agent, runId, occurredAt, danwaTarget, activity, grants} action = do
  useLabels <- patch (PatchId "shikigami-emit-signal-labels-v1")
  ordinalRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        EmitSignal label sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \current -> (current + 1, current))
          let stepName
                | useLabels = StepName ("emit-signal:" <> label)
                | otherwise = StepName ("emit-signal:" <> Text.pack (show ordinal))
          enqueueSinkIntentStep grants stepName agent runId ordinal occurredAt danwaTarget (resolveSinkRecipient sink activity) sink output
    )
    action

runActivity :: ActivityEnvelope -> Eff (Activity : es) a -> Eff es a
runActivity activity =
  interpret \_ -> \case
    CurrentActivity -> pure activity
