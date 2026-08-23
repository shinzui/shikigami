-- | The @KizashiSignal@ sink handler: build a @CreateSignalReq@ from the sink config
-- and the behavior output, and POST it to a kizashi base URL (the C4 contract). Built
-- against a stub kizashi server; swapping the real kizashi base URL needs no code change.
module Shikigami.Sink.KizashiClient
  ( KizashiError (..),
    buildSignalReq,
    postSignal,
    renderKizashiError,
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config (KizashiConfig (..))
import Shikigami.Sink.Http (HttpEnv, HttpFailure, postJSON, renderHttpFailure)
import Shikigami.Sink.Permission (AgentIdentity (..))
import Shikigami.Sink.Recipient (recipientFor)
import Shikigami.Sink.Wire (CreateSignalReq (..), SignalResponse (..))

data KizashiError = KizashiHttpError !HttpFailure | KizashiDecodeError !Text
  deriving stock (Eq, Show)

renderKizashiError :: KizashiError -> Text
renderKizashiError = \case
  KizashiHttpError failure -> renderHttpFailure failure
  KizashiDecodeError detail -> "decode SignalResponse: " <> detail

-- | Build the C4 request from a @KizashiSignal@ sink + the behavior output. Fails for
-- any other sink variant.
--
-- The @Maybe Text@ is what the declaration's @recipientFrom@ strategy resolved
-- to, decided upstream where the trigger activity is available; see
-- "Shikigami.Sink.Recipient" for why resolution does not happen here and for the
-- precedence 'recipientFor' applies.
buildSignalReq :: KizashiConfig -> Maybe Text -> Sink -> AgentIdentity -> Value -> Either Text CreateSignalReq
buildSignalReq KizashiConfig {defaultRecipient = fallbackRecipient} resolvedRecipient sink (AgentIdentity nm) output =
  case sink of
    KizashiSignal
      { source = src,
        signalType = st,
        priority = pr,
        importance = imp,
        defaultRecipient = mrec,
        intentTemplate = tmpl,
        extraContextTags = tags
      } ->
        Right
          CreateSignalReq
            { actor = nm,
              recipient = recipientFor fallbackRecipient resolvedRecipient mrec,
              source = src,
              signalType = st,
              intent = tmpl,
              priority = pr,
              importance = fromIntegral imp,
              contextTags = tags <> activityRefTags output
            }
    _ -> Left "buildSignalReq: not a KizashiSignal sink"

-- | If the behavior output carries an @activity_ref@ string, surface it as a
-- @context_tag@ back-reference (the seed detectors' rule).
activityRefTags :: Value -> [Text]
activityRefTags (Object o) =
  case KeyMap.lookup "activity_ref" o of
    Just (String s) -> [s]
    _ -> []
activityRefTags _ = []

-- | POST the request to @<baseUrl>/v1/signals@ and decode the response.
postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either KizashiError SignalResponse)
postSignal http cfg req = do
  let url = baseUrl cfg <> "/v1/signals"
  respE <- postJSON http url req
  pure $ case respE of
    Left failure -> Left (KizashiHttpError failure)
    Right body -> case eitherDecode body of
      Left de -> Left (KizashiDecodeError (Text.pack de))
      Right sr -> Right sr
