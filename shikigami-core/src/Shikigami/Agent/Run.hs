-- | Shared values and leaf operations used by the durable agent-run workflow.
-- The workflow itself owns the session lifecycle; this module owns only the
-- reusable memory, rendering, and activity-ingest operations around it.
module Shikigami.Agent.Run
  ( AgentRunResult (..),
    behaviorKindText,
    recallPriorLearnings,
    recallQuery,
    renderLearning,
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
import Kioku.Id (MemoryId, SessionId, genMemoryId)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.Embedding qualified as Embedding
import Kioku.Recall qualified as Recall
import Kioku.Recall.Capability qualified as RecallCapability
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), RecallLimit, recallLimitInt)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiReadContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude

-- | The result of an agent run with memory.
data AgentRunResult = AgentRunResult
  { sessionId :: !SessionId,
    recalledPrior :: ![MemoryRecord], -- what the agent remembered from earlier runs
    behaviorOutput :: !Value, -- the behavior's result value
    recordedMemId :: !(Maybe MemoryId) -- the learning recorded this run (Nothing under Never)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

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
