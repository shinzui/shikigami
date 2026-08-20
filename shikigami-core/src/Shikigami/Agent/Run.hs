-- | The run-with-memory seam: wrap 'runBehavior' with the kioku session/memory
-- lifecycle. A run opens a kioku session scoped to the agent, recalls the agent's
-- prior learnings, runs the behavior, records the output as a durable kioku memory
-- under the agent scope, then completes the session (or fails it on error). This is
-- the observable replacement of the spec's bespoke @agent_runs@ table: a run is a
-- kioku Session, a learning is a kioku Memory.
module Shikigami.Agent.Run
  ( AgentRunResult (..),
    behaviorKindText,
    recallPriorLearnings,
    recallQuery,
    renderLearning,
    runAgentWithMemory,
    recordActivityAsMemory,
    renderMemoryRecord,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Text (encodeToLazyText)
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord (..), MemoryType (MemoryPattern))
import Kioku.App (AppEnv, runAppIO)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.Embedding qualified as Embedding
import Kioku.Recall qualified as Recall
import Kioku.Recall.Capability qualified as RecallCapability
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), FailSessionData (..), StartSessionData (..))
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), MemoryPolicy (..), RecallLimit, RecordPolicy (..), recallLimitInt)
import Shikigami.Behavior.Run (BehaviorEnv, BehaviorInput (..), behaviorModelId, runBehavior)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiReadContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import System.IO (hPutStrLn, stderr)

-- | The result of an agent run with memory.
data AgentRunResult = AgentRunResult
  { sessionId :: !SessionId,
    recalledPrior :: ![MemoryRecord], -- what the agent remembered from earlier runs
    behaviorOutput :: !Value, -- the behavior's result value
    recordedMemId :: !(Maybe MemoryId) -- the learning recorded this run (Nothing under Never)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Run an agent end to end with memory. The scope is keyed by the agent's stable
-- name so memory accumulates across the agent's runs.
--
-- Every kioku result on this path is checked. This is the one-off harness that
-- @shikigami-agent-run@ drives, so its contract is a human reading a terminal
-- rather than a queue: a store failure becomes a 'Left' naming which write could
-- not happen, instead of a run that prints a successful result having opened no
-- session and persisted no memory.
runAgentWithMemory ::
  AppEnv -> BehaviorEnv -> AgentDecl -> Value -> IO (Either Text AgentRunResult)
runAgentWithMemory appEnv behEnv decl@AgentDecl {name = agentName', memory = MemoryPolicy {recallLimit = declaredRecallLimit, recordPolicy = declaredRecordPolicy}} payload = do
  let scope' = agentScope agentName'
      focusTxt = behaviorKindText (behavior decl)
  startedAt' <- getCurrentTime
  sid <- genSessionId
  -- 1. open the session (replaces the spec's agent_runs insert)
  started <-
    runAppIO appEnv $
      Session.start
        StartSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor agentName',
            ownerPrincipal = Nothing,
            agentId = agentName',
            focus = focusTxt,
            scope = scope',
            subjectRef = Just (idText sid),
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = startedAt'
          }
  case kiokuAnswer "open the session" started of
    Left detail -> pure (Left detail)
    Right _ -> do
      -- 2. recall what this agent already knows (empty on the first ever run)
      prior <- recallPriorLearnings appEnv declaredRecallLimit scope' (recallQuery decl focusTxt payload)
      -- 3. run the behavior, on what triggered it and what it already knows
      behaviorE <- runBehavior behEnv decl BehaviorInput {payload = payload, recalled = prior}
      case behaviorE of
        Left runErr -> do
          let runErrText = Text.pack (show runErr)
          when (declaredRecordPolicy == Always) $
            recordFailureLearningBestEffort appEnv agentName' sid scope' runErrText
          failedAt' <- getCurrentTime
          failed <-
            runAppIO appEnv $
              Session.failSession
                FailSessionData
                  { sessionId = sid,
                    memorySpaceId = shikigamiMemorySpace,
                    actorPrincipal = agentActor agentName',
                    failedAt = failedAt',
                    errorMessage = runErrText
                  }
          -- The run failed either way; if the failure could not be recorded, say
          -- both things rather than reporting only the half that reached a store.
          pure case kiokuAnswer "mark the session failed" failed of
            Left detail -> Left (runErrText <> " (and " <> detail <> ")")
            Right _ -> Left runErrText
        Right output -> do
          -- 4. record this run's learning as a durable memory under the agent scope
          recorded <-
            case declaredRecordPolicy of
              Never -> pure (Right Nothing)
              OnSuccess -> fmap Just <$> recordLearningNow sid scope' focusTxt output
              Always -> fmap Just <$> recordLearningNow sid scope' focusTxt output
          case recorded of
            Left detail -> pure (Left detail)
            Right recordedMemId -> do
              -- 5. complete the session
              completedAt' <- getCurrentTime
              completed <-
                runAppIO appEnv $
                  Session.complete
                    CompleteSessionData
                      { sessionId = sid,
                        memorySpaceId = shikigamiMemorySpace,
                        actorPrincipal = agentActor agentName',
                        completedAt = completedAt',
                        -- Which model produced the output, so a stub run stays
                        -- distinguishable from a real one after the log has rotated.
                        modelUsed = Just (behaviorModelId behEnv),
                        summary = Just "agent-run completed"
                      }
              pure case kiokuAnswer "complete the session" completed of
                Left detail -> Left detail
                Right _ ->
                  Right
                    AgentRunResult
                      { sessionId = sid,
                        recalledPrior = prior,
                        behaviorOutput = output,
                        recordedMemId
                      }
  where
    recordLearningNow sid scope' focusTxt output =
      recordRunMemory
        appEnv
        agentName'
        sid
        scope'
        (renderLearning output)
        (Set.fromList ["agent-run", focusTxt])

-- | Collapse kioku's two answers into one message naming the write that did not
-- happen.
--
-- Kioku answers on two layers and both were discarded here: the outer
-- @Either StoreError@ says whether the store could be reached, and the inner
-- @Either SessionWriteError@ (or @MemoryWriteError@) says whether it accepted
-- the command. This module's reader is a person at a terminal, so both collapse
-- into prose rather than into a retry classification.
kiokuAnswer :: (Show e) => Text -> Either StoreError (Either e a) -> Either Text a
kiokuAnswer what = \case
  Left storeError -> Left ("could not " <> what <> ": " <> Text.pack (show storeError))
  Right (Left refusal) -> Left ("could not " <> what <> ", kioku refused it: " <> Text.pack (show refusal))
  Right (Right value) -> Right value

-- | Write the \"why did this run fail\" learning, and carry on if the store will
-- not take it.
--
-- The caller is already on the failure path and must still mark the session
-- failed, so this write may not decide the run's outcome. What it may not do is
-- disappear. This module's reader is a person at a terminal, so it says so there.
recordFailureLearningBestEffort :: AppEnv -> Text -> SessionId -> MemoryScope -> Text -> IO ()
recordFailureLearningBestEffort appEnv agentName' sid scope' runErrText = do
  recorded <-
    recordRunMemory
      appEnv
      agentName'
      sid
      scope'
      ("run failed: " <> runErrText)
      (Set.fromList ["agent-run", "failure"])
  case recorded of
    Right _ -> pure ()
    Left detail -> hPutStrLn stderr ("shikigami: best-effort failure learning was skipped: " <> Text.unpack detail)

recordRunMemory :: AppEnv -> Text -> SessionId -> MemoryScope -> Text -> Set.Set Text -> IO (Either Text MemoryId)
recordRunMemory appEnv agentName' sid scope' content' tags' = do
  mid <- genMemoryId
  recordedAt' <- getCurrentTime
  recordedE <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor agentName',
            ownerPrincipal = Nothing,
            agentId = agentName',
            sessionId = Just sid,
            scope = scope',
            memoryType = MemoryPattern,
            content = content',
            priority = 100,
            confidence = MediumConfidence,
            tags = tags',
            supersedes = Nothing,
            recordedAt = recordedAt'
          }
  pure (mid <$ kiokuAnswer "record the run's learning" recordedE)

-- | Map an @activity.v1@ Activity Envelope into a kioku memory under the agent
-- scope: the envelope @payload@ becomes the memory content, and the envelope
-- @verb@/@subject.type@ become searchable tags. An envelope the agent produced
-- (@actor.kind: "agent"@) is exactly a learning to capture. Returns the new memory id.
recordActivityAsMemory :: AppEnv -> AgentDecl -> ActivityEnvelope -> IO (Either Text MemoryId)
recordActivityAsMemory appEnv AgentDecl {name = agentName'} env = do
  let ActivityEnvelope {occurredAt = oat, verb = vb, payload = pl, subject = subj} = env
      Subject {subjectType = sty} = subj
      scope' = agentScope agentName'
      tags' = Set.fromList ["verb:" <> vb, "subject:" <> sty]
      content' = TL.toStrict (encodeToLazyText pl)
  mid <- genMemoryId
  recordedAt' <- maybe getCurrentTime pure (iso8601ParseM (Text.unpack oat))
  res <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor agentName',
            ownerPrincipal = Nothing,
            agentId = agentName',
            sessionId = Nothing,
            scope = scope',
            memoryType = MemoryPattern,
            content = content',
            priority = 100,
            confidence = MediumConfidence,
            tags = tags',
            supersedes = Nothing,
            recordedAt = recordedAt'
          }
  pure $ case res of
    Right (Right _) -> Right mid
    _ -> Left "failed to record activity memory"

-- | Map a behavior arm to a short focus label for the session/memory.
behaviorKindText :: Behavior -> Text
behaviorKindText b = case b of
  ShikumiProgram {} -> "ShikumiProgram"
  Skill {} -> "Skill"
  Deterministic {} -> "Deterministic"
  Flow {} -> "Flow"

-- | Turn the behavior's output JSON into a memory's @content@: prefer a @summary@ or
-- @reply@ string field, falling back to the compact JSON encoding.
renderLearning :: Value -> Text
renderLearning v = case v of
  Object o -> case KeyMap.lookup "summary" o <|> KeyMap.lookup "reply" o of
    Just (String s) -> s
    _ -> compact v
  _ -> compact v
  where
    compact = TL.toStrict . encodeToLazyText

-- | A one-line render of a recalled memory for the @agent-run@ demo output.
renderMemoryRecord :: MemoryRecord -> Text
renderMemoryRecord (MemoryRecord {memoryId = mid, memoryType = mt, confidence = cf, content = c}) =
  mid <> " [" <> mt <> "/" <> cf <> "] " <> c

recallPriorLearnings :: AppEnv -> RecallLimit -> MemoryScope -> Text -> IO [MemoryRecord]
recallPriorLearnings appEnv limit scope' query = do
  cfg <- Embedding.resolveEmbeddingConfig
  -- Kioku 0.2 probes the vector path against the dimension count the process is
  -- configured with, so it can report a configured/declared mismatch instead of
  -- silently failing every embedding write on the ::vector cast.
  capability <-
    runAppIO appEnv (RecallCapability.detectVectorCapability (Embedding.dimensions cfg)) <&> \case
      Right cap -> cap
      Left _ -> RecallCapability.VectorExtensionUnavailable
  recalled <-
    runAppIO appEnv $
      Recall.legacyRecall
        (Embedding.toEmbeddingModel cfg)
        capability
        shikigamiReadContext
        Recall.RecallRequest
          { memorySpaceId = shikigamiMemorySpace,
            scope = scope',
            query,
            strategy = Recall.Hybrid,
            maxResults = recallLimitInt limit
          }
  -- Two Eithers now: the outer one is runAppIO's, the inner one is recall's own
  -- "could not be asked" channel, which Kioku 0.4 added so an unrunnable query
  -- stops looking like a query that matched nothing. Both fall through to the
  -- read-model path, as before.
  case recalled of
    Right (Right hits)
      | not (null hits) -> pure (Recall.memory <$> hits)
    _ -> recallActiveByScope appEnv (recallLimitInt limit) scope'

recallActiveByScope :: AppEnv -> Int -> MemoryScope -> IO [MemoryRecord]
recallActiveByScope appEnv limit scope' = do
  priorE <- runAppIO appEnv $ Recall.getActiveByScope shikigamiMemorySpace scope'
  pure $ case priorE of
    Right (Right ms) -> take limit ms
    _ -> []

-- | The text a run recalls against: who is asking, what kind of behavior is
-- running, what the agent is for, and what this particular event said.
--
-- It used to be @agentName focus "summary digest learning prior memory"@ — the
-- same string on every run of an agent, so a hybrid vector/text recall could
-- only rank memories by their similarity to a constant. Whatever came back was
-- the same ten memories every time regardless of what triggered the run. Adding
-- the declaration's description and the payload's own words makes retrieval
-- about /this/ event: a payload of @{"text":"customer says cancel"}@ asks about
-- cancellation.
--
-- Capped at 512 characters because the result feeds an embedding, not a prompt;
-- a long payload should not push the agent's own description out of the query.
recallQuery :: AgentDecl -> Text -> Value -> Text
recallQuery AgentDecl {name = agentName', description = desc} focusTxt payload =
  Text.take 512 (Text.unwords (agentName' : focusTxt : desc : payloadTerms payload))

-- | The string leaves of a trigger payload: the top level and one level below
-- it, in encounter order.
--
-- One level down is where the interesting words are — an activity envelope puts
-- them under @payload@, a danwa turn under @content@ — and going deeper would
-- spend the cap on structure rather than prose.
payloadTerms :: Value -> [Text]
payloadTerms = \case
  Object o -> concatMap nestedTerms (KeyMap.elems o)
  other -> nestedTerms other
  where
    nestedTerms = \case
      String s -> [s]
      Array vs -> [s | String s <- toList vs]
      Object o -> [s | String s <- KeyMap.elems o]
      _ -> []
