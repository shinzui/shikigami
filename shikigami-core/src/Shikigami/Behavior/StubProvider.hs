-- | A deterministic, key-free @baikai@ provider for the skill arm. Registering it
-- installs a handler for the @Custom "stub"@ API tag whose @complete@ ignores the
-- request and returns a fixed assistant reply, so the skill arm runs with no API key.
-- The matching 'stubModel' carries the same @Custom "stub"@ tag so @completeRequest@
-- dispatches to this provider.
module Shikigami.Behavior.StubProvider
  ( registerStubProvider,
    stubApiProvider,
    stubApi,
    stubModel,
    stubReplyText,
  )
where

import Baikai.Api (Api (Custom))
import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Evidence
  ( CallStatus (CallSucceeded),
    EndpointIdentity (..),
    Observed (Observed),
    ThinkingAdjustment (ThinkingDroppedUnsupportedHost),
    ThinkingMode (ThinkingModeUnsupported),
    ThinkingTranslation (..),
    TransportKind (TransportAgentRun),
    baseEvidence,
    commitmentDigest,
    configurationDigest,
    newCallId,
    noThinkingRequested,
  )
import Baikai.Model (Model, emptyModel)
import Baikai.Model qualified as Model
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider, apiProviderWith, registerApiProvider)
import Baikai.Response (Response, emptyResponse)
import Baikai.Stream (liftCompleteToStream)
import Control.Lens ((&), (.~))
import Data.Aeson (object, toJSON, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.Vector qualified as V

-- | The API tag the stub answers for. Using the @Custom@ escape hatch avoids
-- colliding with any real provider registered for a closed tag.
stubApi :: Api
stubApi = Custom "stub"

-- | The fixed reply text the stub returns; the skill arm renders it into the output.
stubReplyText :: Text
stubReplyText = "stub-skill: instructions acknowledged; no model was called"

-- | A model whose API tag is 'stubApi', so @completeRequest stubModel@ dispatches to
-- 'stubApiProvider'. Built from baikai's 'emptyModel' base.
stubModel :: Model
stubModel =
  emptyModel
    & #modelId .~ "stub-v1"
    & #name .~ "Stub LLM"
    & #api .~ stubApi
    & #provider .~ "stub"

-- | The fixed response: baikai's 'emptyResponse' base with its assistant content replaced
-- by a single text block carrying 'stubReplyText'.
stubResponse :: Response
stubResponse =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantText (TextContent {text = stubReplyText}))
    & #api .~ stubApi
    & #provider .~ "stub"

-- | The provider whose @complete@ ignores the request and returns 'stubResponse'.
stubApiProvider :: ApiProvider
stubApiProvider =
  apiProviderWith stubApi (liftCompleteToStream completeStub) completeStub
    & #describeThinking .~ stubThinking

completeStub :: Model -> context -> Options -> IO Response
completeStub model _context options =
  case Options.evidence options of
    Nothing -> pure stubResponse
    Just request -> do
      now <- getCurrentTime
      callId <- newCallId
      let requestEnvelope =
            object
              [ "provider" .= Model.provider model,
                "model" .= Model.modelId model,
                "options" .= toJSON options
              ]
          responseEnvelope = object ["reply" .= stubReplyText]
          terminal =
            baseEvidence
              request
              callId
              stubEndpoint
              (Model.modelId model)
              (stubThinking model options)
              now
              now
              CallSucceeded
              (commitmentDigest requestEnvelope)
              (configurationDigest requestEnvelope)
              & #responseCommitment .~ Observed (commitmentDigest responseEnvelope)
      pure (stubResponse & #evidence .~ Just terminal)

stubEndpoint :: EndpointIdentity
stubEndpoint =
  EndpointIdentity
    { provider = "stub",
      api = "stub",
      transport = TransportAgentRun,
      endpoint = Nothing,
      baikaiVersion = "0.7.0.0",
      implementationVersion = Just "shikigami-stub-v1"
    }

-- | What the stub would do with a reasoning-effort request: nothing, and it says so.
--
-- baikai 0.5 added this to 'ApiProvider' for the pre-dispatch strictness gate, which must be
-- able to refuse /before/ a request is built. The stub calls no model and puts nothing on any
-- wire, so the honest answer is that the host exposes no reasoning controls at all — not that
-- the request was expressed. Reporting anything weaker would let a caller who asked for
-- guaranteed evidence pass the gate and then receive a fixed string.
--
-- The two cases stay distinct because baikai draws the distinction: a caller who set no level
-- gets 'noThinkingRequested', while a caller who asked for one gets 'ThinkingModeUnsupported'
-- with the drop recorded, which is what a reader of the evidence needs to tell "nobody asked"
-- from "asked and could not be served".
stubThinking :: Model -> Options -> ThinkingTranslation
stubThinking _model opts =
  case Options.thinking opts of
    Nothing -> noThinkingRequested
    Just level ->
      ThinkingTranslation
        { requested = Just level,
          mode = ThinkingModeUnsupported,
          effortText = Nothing,
          budgetTokens = Nothing,
          wireField = Nothing,
          displayText = Nothing,
          adjustments = [ThinkingDroppedUnsupportedHost level]
        }

-- | Install the stub provider into baikai's process-global registry. Idempotent
-- (insert is overwrite-by-tag), so calling it twice is harmless.
registerStubProvider :: IO ()
registerStubProvider = registerApiProvider stubApiProvider
