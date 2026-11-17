{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | The Kikan output adapters (EP-8 M3 of MasterPlan 22).
--
-- @kawa.digest@ publishes a run's result to the Kawa doorway as one C1
-- activity envelope, the same envelope the @KawaDigest@ sink builds. It is
-- the default output of a Kikan composition, so a declaration with no
-- @outputs@ line reports to Kawa there and to a local report under the stock
-- composition. The other Kikan sinks keep their @sinks@ path; EP-10 moves
-- this module, with them, into the Kikan binding package.
--
-- Configuration: @{"subjectKind": text, "verb": text}@, both non-empty. The
-- envelope's idempotency key is the agent, run and ordinal, so a replayed
-- delivery step posts the same event and Kawa deduplicates it.
module Shikigami.Output.Kikan
  ( kawaDigestKind,
    kawaDigestAdapter,
    defaultKawaDigest,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.KindID (genKindID, toText)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate (ActorKind (AgentActor), activityCoordinate)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Output
import Shikigami.Sink.Config (KawaConfig)
import Shikigami.Sink.Http (HttpEnv)
import Shikigami.Sink.KawaClient (contextRefsFromOutput, postEnvelope, renderKawaError, subjectIdFromOutput)

kawaDigestKind :: OutputKind
kawaDigestKind = either (error . Text.unpack) id (mkOutputKind "kawa.digest")

-- | A Kikan worker's default output: an @agent-run@ subject @reported@.
defaultKawaDigest :: OutputDecl
defaultKawaDigest =
  OutputDecl
    { kind = kawaDigestKind,
      config = object ["subjectKind" .= ("agent-run" :: Text), "verb" .= ("reported" :: Text)]
    }

data DigestConfig = DigestConfig {subjectKind :: !Text, verb :: !Text}

configOf :: Value -> Either Text DigestConfig
configOf = \case
  Object fields -> DigestConfig <$> required "subjectKind" fields <*> required "verb" fields
  _ -> Left "the configuration must be an object"
  where
    required name fields = case KeyMap.lookup name fields of
      Just (String value) | not (Text.null (Text.strip value)), Text.length value <= 128 -> Right value
      _ -> Left (Text.pack (show name) <> " must be a non-empty string of at most 128 characters")

kawaDigestAdapter :: HttpEnv -> KawaConfig -> OutputAdapter
kawaDigestAdapter http kawa =
  OutputAdapter
    { kind = kawaDigestKind,
      validate = fmap (const ()) . configOf,
      deliver = \OutputDelivery {run, agent, ordinal, output, result} -> case (configOf output.config, contextRefsFromOutput result) of
        (Left problem, _) -> pure (Left problem)
        (_, Left problem) -> pure (Left ("invalid Kawa payload: " <> problem))
        (Right DigestConfig {subjectKind, verb}, Right contextRefs) -> do
          activityId <- genKindID @"act"
          now <- getCurrentTime
          let actorId = agentNameText agent
              envelope =
                ActivityEnvelope
                  { activityId = activityCoordinate (toText activityId),
                    occurredAt = activityCoordinate (Text.pack (iso8601Show now)),
                    source = activityCoordinate "shinzui/shikigami",
                    actor = Actor {kind = AgentActor, id = activityCoordinate actorId, session = Nothing},
                    subject = Subject {kind = activityCoordinate subjectKind, subjectId = activityCoordinate (subjectIdFromOutput result actorId)},
                    verb = activityCoordinate verb,
                    payload = result,
                    contextRefs,
                    idempotencyKey = activityCoordinate (actorId <> ":" <> run.unWorkflowId <> ":output-" <> Text.pack (show ordinal))
                  }
          posted <- postEnvelope http kawa envelope
          pure case posted of
            Left problem -> Left (renderKawaError problem)
            Right canonical ->
              Right OutputReceipt {kind = outputKindText kawaDigestKind, location = canonical, detail = "published to Kawa"}
    }
