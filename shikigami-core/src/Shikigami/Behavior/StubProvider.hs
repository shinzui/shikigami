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
  ( ThinkingAdjustment (ThinkingDroppedUnsupportedHost),
    ThinkingMode (ThinkingModeUnsupported),
    ThinkingTranslation (..),
    noThinkingRequested,
  )
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model (..), _Model)
import Baikai.Options (Options (..))
import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..), _Response)
import Baikai.Stream (liftCompleteToStream)
import Data.Text (Text)
import Data.Vector qualified as V

-- | The API tag the stub answers for. Using the @Custom@ escape hatch avoids
-- colliding with any real provider registered for a closed tag.
stubApi :: Api
stubApi = Custom "stub"

-- | The fixed reply text the stub returns; the skill arm renders it into the output.
stubReplyText :: Text
stubReplyText = "stub-skill: instructions acknowledged; no model was called"

-- | A model whose API tag is 'stubApi', so @completeRequest stubModel@ dispatches to
-- 'stubApiProvider'. Built from baikai's @_Model@ base.
stubModel :: Model
stubModel =
  _Model
    { modelId = "stub-v1",
      name = "Stub LLM",
      api = stubApi,
      provider = "stub"
    }

-- | The fixed response: baikai's @_Response@ base with its assistant content replaced
-- by a single text block carrying 'stubReplyText'.
stubResponse :: Response
stubResponse =
  let base = _Response
      msg = (message base) {content = V.singleton (AssistantText (TextContent {text = stubReplyText}))}
   in base {message = msg, api = stubApi, provider = "stub"}

-- | The provider whose @complete@ ignores the request and returns 'stubResponse'.
stubApiProvider :: ApiProvider
stubApiProvider =
  ApiProvider
    { apiTag = stubApi,
      stream = liftCompleteToStream (\_model _ctx _opts -> pure stubResponse),
      complete = \_model _ctx _opts -> pure stubResponse,
      describeThinking = stubThinking
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
  case thinking opts of
    Nothing -> noThinkingRequested
    Just level ->
      ThinkingTranslation
        { requested = Just level,
          mode = ThinkingModeUnsupported,
          effortText = Nothing,
          budgetTokens = Nothing,
          wireField = Nothing,
          adjustments = [ThinkingDroppedUnsupportedHost level]
        }

-- | Install the stub provider into baikai's process-global registry. Idempotent
-- (insert is overwrite-by-tag), so calling it twice is harmless.
registerStubProvider :: IO ()
registerStubProvider = registerApiProvider stubApiProvider
