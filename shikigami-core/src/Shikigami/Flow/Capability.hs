{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Capability
  ( Activity,
    Memory,
    MemoryEnv (..),
    MemoryQuery (..),
    RememberOptions (..),
    Sink,
    SinkEnv (..),
    currentActivity,
    defaultRememberOptions,
    deterministicFlowMemoryId,
    emitSignal,
    recall,
    recordFlowMemory,
    remember,
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
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, WorkflowId (..), WorkflowName (..), currentRunGeneration, currentWorkflow, patch, step)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.App (AppEnv, runAppIO)
import Kioku.Id (MemoryId, SessionId, genMemoryId)
import Kioku.Memory (MemoryWriteError)
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
  Recall :: Text -> MemoryQuery -> Memory m [MemoryRecord]
  Remember :: Text -> RememberOptions -> Value -> Memory m MemoryId

type instance DispatchOf Memory = Dynamic

data Sink :: Effect where
  EmitSignal :: Text -> Agent.Sink -> Value -> Sink m SinkResult

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
data RememberOptions = RememberOptions
  { priority :: !Int,
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
    { priority = 100,
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
recall :: (Memory :> es) => Text -> MemoryQuery -> Eff es [MemoryRecord]
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
remember :: (Memory :> es) => Text -> Value -> Eff es MemoryId
remember label value = send (Remember label defaultRememberOptions value)

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

-- | The guard that decides whether this run journals its memory operations.
--
-- Declared as a @patch@ block in @domain\/shikigami-agent-run.keiro@; the
-- generated @declaredPatches@ carries it into 'shikigamiActivePatches', so
-- nothing activates it by hand.
flowMemoryStepsPatch :: PatchId
flowMemoryStepsPatch = PatchId "shikigami-flow-memory-steps-v1"

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
--
-- The 'patch' is read once per interpreted flow run, not per operation, so every
-- memory operation of one instance agrees about which scheme it is on — the same
-- reason 'runSink' reads its own guard once. An instance already in flight when
-- this shipped has no recorded patch set, takes 'False', and keeps the
-- un-journaled behavior its journal was written under; a fresh instance records
-- the set, takes 'True', and journals for good. Delete the 'False' branch and
-- the patch id together, and only once no pre-change flow can still resume; see
-- @docs\/workflow-versioning.md@.
runMemory :: (Workflow :> es, IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
runMemory env@MemoryEnv {appEnv, agent = decl@AgentDecl {memory = MemoryPolicy {recallLimit}}} action = do
  journalMemory <- patch flowMemoryStepsPatch
  interpret
    ( \_ -> \case
        Recall label MemoryQuery {query} ->
          let fetch = liftIO (recallPriorLearnings appEnv recallLimit (agentScope (name decl)) query)
           in if journalMemory
                then step (StepName ("recall-" <> label)) fetch
                else fetch
        Remember label opts value
          | journalMemory -> do
              (wfName, wfId) <- currentWorkflow
              generation <- currentRunGeneration
              let mid = deterministicFlowMemoryId wfName wfId generation label
              step (StepName ("remember-" <> label)) (liftIO (writeMemory env mid opts value))
          | otherwise -> liftIO do
              -- The pre-patch path: a fresh random id per execution, which is
              -- what makes a replay duplicate the row. Retained only so an
              -- in-flight instance keeps the behavior its journal was written
              -- under.
              mid <- genMemoryId
              writeMemory env mid opts value
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
-- Hashes UTF-8 bytes rather than @fromEnum@ over 'Char's. This deliberately
-- diverges from @deterministicOutboxIdForMessage@ in "Shikigami.Agent.Workflow",
-- whose @fromEnum@ truncates any code point above 255 and is safe only because
-- its inputs are ASCII by construction. A workflow name is not: nothing in the
-- type system keeps it ASCII. Do not \"fix\" this back to match its neighbour.
deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> Text -> MemoryId
deterministicFlowMemoryId (WorkflowName wfName) (WorkflowId wfId) generation label =
  KindID.decorateKindID $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      ByteString.unpack $
        TextEncoding.encodeUtf8 $
          Text.intercalate ":" ["shikigami:flow-memory", wfName, wfId, Text.pack (show generation), label]

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
  MemoryEnv {appEnv, agent = decl, sessionId}
  mid
  RememberOptions {priority, confidence, memoryType, supersedes, extraTags}
  value = do
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
              memoryType,
              content = renderLearning value,
              priority,
              confidence,
              tags = Set.fromList ["flow", focus] <> extraTags,
              supersedes,
              recordedAt
            }
    runAppIO appEnv (MemoryStore.record record) >>= \case
      Right outcome -> pure outcome
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
