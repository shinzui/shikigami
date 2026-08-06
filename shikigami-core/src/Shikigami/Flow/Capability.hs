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
import Keiro.Workflow (StepName (..), Workflow)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.App (AppEnv, runAppIO)
import Kioku.Id (MemoryId, SessionId, genMemoryId)
import Kioku.Memory qualified as MemoryStore
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kiroku.Store.Effect (Store)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Run (behaviorKindText, recallPriorLearnings, renderLearning)
import Shikigami.Flow.SinkOutbox (enqueueSinkIntentStep)
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
  EmitSignal :: Agent.Sink -> Value -> Sink m SinkResult

type instance DispatchOf Sink = Dynamic

data Activity :: Effect where
  CurrentActivity :: Activity m ActivityEnvelope

type instance DispatchOf Activity = Dynamic

recall :: (Memory :> es) => MemoryQuery -> Eff es [MemoryRecord]
recall query' = send (Recall query')

remember :: (Memory :> es) => Value -> Eff es MemoryId
remember value = send (Remember value)

emitSignal :: (Sink :> es) => Agent.Sink -> Value -> Eff es SinkResult
emitSignal sink output = send (EmitSignal sink output)

currentActivity :: (Activity :> es) => Eff es ActivityEnvelope
currentActivity = send CurrentActivity

runMemory :: (IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
runMemory MemoryEnv {appEnv, agent = decl, sessionId} =
  interpret \_ -> \case
    Recall MemoryQuery {query} ->
      liftIO (recallPriorLearnings appEnv (agentScope (name decl)) query)
    Remember value -> liftIO do
      mid <- genMemoryId
      recordedAt <- getCurrentTime
      let focus = behaviorKindText (behavior decl)
          record =
            RecordMemoryData
              { memoryId = mid,
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

runSink :: (Workflow :> es, Store :> es, IOE :> es) => SinkEnv -> Eff (Sink : es) a -> Eff es a
runSink SinkEnv {agent, runId, occurredAt, danwaTarget, activity, grants} action = do
  ordinalRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        EmitSignal sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \current -> (current + 1, current))
          let stepName = StepName ("emit-signal:" <> Text.pack (show ordinal))
          enqueueSinkIntentStep grants stepName agent runId ordinal occurredAt danwaTarget (resolveSinkRecipient sink activity) sink output
    )
    action

runActivity :: ActivityEnvelope -> Eff (Activity : es) a -> Eff es a
runActivity activity =
  interpret \_ -> \case
    CurrentActivity -> pure activity
