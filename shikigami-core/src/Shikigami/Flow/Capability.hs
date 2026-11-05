{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Capability
  ( Activity,
    Memory,
    MemoryEnv (..),
    MemoryQuery (..),
    RememberOptions (..),
    MemoryPriority (..),
    Sink,
    SinkEnv (..),
    currentActivity,
    defaultRememberOptions,
    deterministicFlowMemoryId,
    emitSignal,
    emitSignalTo,
    recall,
    recordFlowMemory,
    remember,
    rememberWith,
    runActivity,
    runMemory,
    runSink,
  )
where

import Data.Aeson (Value)
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef)
import Data.KindID.V7 qualified as KindID
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Hasql.Pool (Pool)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), currentRunGeneration, currentWorkflow, step)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.Id (MemoryId, SessionId)
import Kioku.Memory (MemoryWriteError)
import Kioku.Memory qualified as MemoryStore
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kiroku.Store.Effect (Store)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), MemoryPolicy (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity, ResolvedAgentIdentity)
import Shikigami.Agent.Run (behaviorKindText, recallAgentLearnings, renderLearning)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Sink (GrantSource)
import Shikigami.Sink.Intent (enqueueSinkIntentStep, enqueueSinkIntentStepForRecipient)
import Shikigami.Sink.Types (DanwaTarget, SinkResult)

newtype MemoryQuery = MemoryQuery {query :: Text}
  deriving stock (Eq, Show)

data MemoryEnv = MemoryEnv
  { appEnv :: !AppEnv,
    agent :: !AgentDecl,
    identity :: !ResolvedAgentIdentity,
    aliasPool :: !(Maybe Pool),
    sessionId :: !(Maybe SessionId)
  }

data SinkEnv = SinkEnv
  { agent :: !AgentName,
    runId :: !SessionId,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    -- | The activity that triggered the flow, carried so a @KizashiSignal@
    -- emitted from inside it can resolve @recipientFrom = Actor@ the same way
    -- the plain agent path does. A flow with no triggering activity simply
    -- resolves nothing and falls back to the declaration's default.
    activity :: !(Maybe ActivityEnvelope),
    -- | Which grant source the enqueue-time C11 check consults for sinks emitted
    -- from inside a flow.
    grants :: !GrantSource,
    directory :: !DirectoryHandle,
    identity :: !AgentIdentity
  }

data Memory :: Effect where
  Recall :: DeclarationCoordinate "memory-label" -> MemoryQuery -> Memory m [MemoryRecord]
  Remember :: DeclarationCoordinate "memory-label" -> RememberOptions -> Value -> Memory m MemoryId

type instance DispatchOf Memory = Dynamic

data Sink :: Effect where
  EmitSignal :: DeclarationCoordinate "sink-label" -> Agent.Sink -> Value -> Sink m SinkResult
  EmitSignalTo :: DeclarationCoordinate "sink-label" -> DeclarationCoordinate "recipient" -> Agent.Sink -> Value -> Sink m SinkResult

type instance DispatchOf Sink = Dynamic

data Activity :: Effect where
  CurrentActivity :: Activity m ActivityEnvelope

type instance DispatchOf Activity = Dynamic

-- | The metadata a 'Remember' writes alongside its content.
--
-- Every field was a hardcoded constant in this interpreter before flows could
-- choose. 'defaultRememberOptions' holds those same constants, so a flow that
-- does not care keeps recording exactly what it recorded before.
--
-- 'extraTags' is additive on purpose: the interpreter unions it with the
-- @[\"flow\", \<behavior kind\>]@ tags it has always written rather than replacing
-- them, so a flow cannot accidentally un-tag its own memories out of the
-- queries that find them.
newtype MemoryPriority = MemoryPriority Int
  deriving stock (Eq, Show)

data RememberOptions = RememberOptions
  { priority :: !MemoryPriority,
    confidence :: !Confidence,
    memoryType :: !MemoryType,
    supersedes :: !(Maybe MemoryId),
    extraTags :: !(Set Text)
  }
  deriving stock (Eq, Show)

-- | What this interpreter wrote on every flow memory before flows could choose.
defaultRememberOptions :: RememberOptions
defaultRememberOptions =
  RememberOptions
    { priority = MemoryPriority 100,
      confidence = MediumConfidence,
      memoryType = MemoryPattern,
      supersedes = Nothing,
      extraTags = Set.empty
    }

-- | Recall prior learnings, journaling the result under a step name derived
-- from @label@.
--
-- @label@ is a caller-supplied stable token with the same meaning it has for
-- 'emitSignal': short, lowercase, unique among the memory operations of one
-- flow, and never derived from data that varies between a run and its replays.
-- Journaling is what makes recall replay-safe — a resumed or re-invoked run is
-- handed the /recorded/ result list rather than re-querying a store that other
-- runs have written to since, so a flow that branches on what it recalled takes
-- the same branch it took the first time.
--
-- One rule 'emitSignal' does not have applies here. A memory label is also a
-- declared wire word, so it must match @[A-Za-z0-9][A-Za-z0-9_-]*@ (no colons,
-- nothing computed at run time) and, when the flow is registered in
-- "Shikigami.Flow", it must appear as @step recall-\<label\>@ in
-- @domain\/shikigami-agent-run.keiro@. That is what puts these names under
-- @just keiro-gate@ instead of merely being stable by convention.
recall :: (Memory :> es) => DeclarationCoordinate "memory-label" -> MemoryQuery -> Eff es [MemoryRecord]
recall label query' = send (Recall label query')

-- | Record a learning, journaling it under a step name derived from @label@,
-- with the metadata this interpreter has always written.
--
-- @label@ carries the same contract as 'recall'\'s, and the declared step name
-- is @remember-\<label\>@. It does double duty here: besides naming the journal
-- entry, it is an input to the deterministic memory id
-- ('deterministicFlowMemoryId'), which is what makes a crash inside the step
-- window re-write the same row instead of a second one.
--
-- Because the id is deterministic, the arguments to a 'remember' must be a pure
-- function of replay-stable inputs — a note built from journaled step results,
-- not from a fresh clock read or a live query. Kioku answers a second write
-- against a known id idempotently only when the whole semantic payload matches;
-- a payload that drifted yields a conflict rather than a silent second row.
remember :: (Memory :> es) => DeclarationCoordinate "memory-label" -> Value -> Eff es MemoryId
remember label = rememberWith label defaultRememberOptions

-- | 'remember' with the metadata spelled out instead of defaulted.
--
-- Everything 'remember' documents applies unchanged — the label is a declared
-- journal step name, and the payload must be a pure function of replay-stable
-- inputs. The options are part of that payload: kioku compares @priority@,
-- @confidence@, @memoryType@, @tags@, and @supersedes@ when deciding whether a
-- second write under a known id is a retry or a conflict, so options that vary
-- between a run and its replay are as much a bug as content that does.
--
-- @supersedes@ records __lineage__ and nothing more. It writes \"this memory
-- descends from that one\" onto the new row; it does not retire the old one,
-- which stays active and stays recallable. Kioku separates the two deliberately
-- and does the same thing itself: @Kioku.Distill.L1@ records a winner carrying
-- @supersedes@ and then issues a distinct merge command for each target it
-- means to retire. Retiring a flow memory would be a second aggregate write
-- from one capability call, and this capability does not make it.
rememberWith :: (Memory :> es) => DeclarationCoordinate "memory-label" -> RememberOptions -> Value -> Eff es MemoryId
rememberWith label opts value = send (Remember label opts value)

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
emitSignal :: (Sink :> es) => DeclarationCoordinate "sink-label" -> Agent.Sink -> Value -> Eff es SinkResult
emitSignal label sink output = send (EmitSignal label sink output)

-- | Emit to a recipient the caller resolved from configuration. Journaled as
-- @emit-signal-\<label\>@, a name the declaration language can spell.
emitSignalTo :: (Sink :> es) => DeclarationCoordinate "sink-label" -> DeclarationCoordinate "recipient" -> Agent.Sink -> Value -> Eff es SinkResult
emitSignalTo label recipient sink output = send (EmitSignalTo label recipient sink output)

currentActivity :: (Activity :> es) => Eff es ActivityEnvelope
currentActivity = send CurrentActivity

-- | Interpret 'Memory' by journaling every recall and every write as a keiro
-- step named after the caller's label.
--
-- This is what makes flow memory replay-safe, and it closes two distinct holes.
-- A durable workflow re-executes its body on every resume and on every
-- re-invocation of an already-completed instance, answering journaled steps from
-- the journal and running everything else again. Before this interpreter
-- journaled anything, that meant a @recall@ re-queried a store other runs had
-- written to since (so a flow branching on what it recalled could take a
-- different branch than the one its journal records) and a @remember@ minted a
-- fresh id and wrote one extra row per replay.
--
-- The step journal closes the replay hole. It does not close the /crash/ hole:
-- keiro steps are at-least-once at the step boundary, so an action that ran but
-- whose journal append did not commit runs again on resume. That is what
-- 'deterministicFlowMemoryId' is for — the re-execution derives the same id, and
-- kioku answers a second write against a known id as an idempotent success
-- rather than a second row.
--
-- 'currentWorkflow' and 'currentRunGeneration' are read /outside/ the step on
-- purpose. Both are replay-stable by construction, so reading them outside costs
-- nothing and keeps the step body a single IO action whose result is the value
-- being journaled.
runMemory :: (Workflow :> es, IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
runMemory env@MemoryEnv {appEnv, agent = AgentDecl {memory = MemoryPolicy {recallLimit}}, identity, aliasPool} action =
  interpret
    ( \_ -> \case
        Recall label MemoryQuery {query} ->
          step
            (StepName ("recall-" <> declarationCoordinateText label))
            (liftIO (recallAgentLearnings appEnv aliasPool recallLimit identity query))
        Remember label opts value -> do
          (wfName, wfId) <- currentWorkflow
          generation <- currentRunGeneration
          let mid = deterministicFlowMemoryId wfName wfId generation label
          step (StepName ("remember-" <> declarationCoordinateText label)) (liftIO (writeMemory env mid opts value))
    )
    action

-- | 'recordFlowMemory' with kioku's refusal raised rather than returned.
--
-- A conflict is not a duplicate to swallow: it means the payload changed between
-- two attempts under one id, which is a flow building its note from something
-- that is not replay-stable.
writeMemory :: MemoryEnv -> MemoryId -> RememberOptions -> Value -> IO MemoryId
writeMemory env mid opts value =
  recordFlowMemory env mid opts value >>= \case
    Right stored -> pure stored
    Left err -> ioError (userError ("failed to record flow memory: " <> show err))

-- | The memory id a labeled 'Remember' always maps to.
--
-- Keyed on the workflow identity, the journal generation, and the caller's
-- label, so a crash between the record landing and the journal append committing
-- re-derives the __same__ id on resume; kioku answers the second write
-- idempotently rather than writing a second row. The generation is included for
-- the reason 'currentRunGeneration' names: a journal rotated by @continueAsNew@
-- must not collide with the generation before it.
--
-- The tradeoff is a name-based (v5) UUID inside an id family that is otherwise
-- time-ordered (v7), which costs time-sortability for these rows and nothing
-- else. Kioku took the identical tradeoff for distilled L1 atoms
-- (@Kioku.Distill.L1.l1AtomMemoryId@), which is the same construction; it is not
-- exported, so this mints its own.
--
-- Hashes UTF-8 bytes under the same policy as
-- 'Shikigami.Sink.Intent.deterministicOutboxIdForMessage'. The namespace and
-- input tuple remain distinct, so flow-memory ids cannot collide with sink
-- outbox ids.
deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> DeclarationCoordinate "memory-label" -> MemoryId
deterministicFlowMemoryId (WorkflowName wfName) (WorkflowId wfId) generation label =
  KindID.decorateKindID $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      ByteString.unpack $
        TextEncoding.encodeUtf8 $
          Text.intercalate ":" ["shikigami:flow-memory", wfName, wfId, Text.pack (show generation), declarationCoordinateText label]

-- | Write one flow memory under a caller-supplied id, returning kioku's answer.
--
-- Exported because it is the only honest way to test the crash window this
-- interpreter depends on. There is no public API for losing a journal append, so
-- a test calls this the way a re-executed step would: twice with one id and one
-- payload (both must succeed, and one row must exist), then once more with the
-- same id and different content (which must conflict rather than succeed).
--
-- The @Left@ it returns is kioku's domain answer and is the interesting one. A
-- 'Kiroku.Store.Error.StoreError' from the surrounding 'runAppIO' is
-- infrastructure failing rather than the write being refused, and is raised as
-- an 'IOError' the way this interpreter has always raised it.
recordFlowMemory :: MemoryEnv -> MemoryId -> RememberOptions -> Value -> IO (Either MemoryWriteError MemoryId)
recordFlowMemory
  MemoryEnv {appEnv, agent = decl, identity, sessionId}
  mid
  RememberOptions {priority = MemoryPriority priority, confidence, memoryType, supersedes, extraTags}
  value = do
    recordedAt <- getCurrentTime
    let focus = behaviorKindText ((.behavior) decl)
        record =
          RecordMemoryData
            { memoryId = mid,
              memorySpaceId = shikigamiMemorySpace,
              actorPrincipal = agentActor identity,
              ownerPrincipal = Nothing,
              agentId = agentNameText ((.name) decl),
              sessionId,
              scope = agentScope identity,
              memoryType,
              content = renderLearning value,
              priority,
              confidence,
              tags = Set.fromList ["flow", focus] <> extraTags,
              supersedes,
              recordedAt
            }
    runAppIO appEnv (MemoryStore.recordWithContext (shikigamiWriteContext identity) record) >>= \case
      Right outcome -> pure outcome
      Left err -> ioError (userError ("failed to record flow memory: " <> show err))

-- | Journal each emission under its caller's stable label. The payload ordinal
-- retains emission ordering; it never selects a journal record.
runSink :: (Workflow :> es, Store :> es, IOE :> es) => SinkEnv -> Eff (Sink : es) a -> Eff es a
runSink SinkEnv {agent, runId, occurredAt, danwaTarget, activity, grants, directory, identity} action = do
  ordinalRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        EmitSignal label sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \current -> (current + 1, current))
          let stepName = StepName ("emit-signal:" <> declarationCoordinateText label)
          enqueueSinkIntentStep directory grants identity stepName agent runId ordinal occurredAt danwaTarget activity sink output
        EmitSignalTo label recipient sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \current -> (current + 1, current))
          let stepName = StepName ("emit-signal-" <> declarationCoordinateText label)
          enqueueSinkIntentStepForRecipient directory grants identity stepName agent runId ordinal occurredAt danwaTarget activity recipient sink output
    )
    action

runActivity :: ActivityEnvelope -> Eff (Activity : es) a -> Eff es a
runActivity activity =
  interpret \_ -> \case
    CurrentActivity -> pure activity
