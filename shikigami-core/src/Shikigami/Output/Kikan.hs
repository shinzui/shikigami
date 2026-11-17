{-# LANGUAGE DataKinds #-}

-- | The Kikan output adapters (EP-8 M3 and plan 135 M3 of MasterPlan 22).
--
-- Five kinds, each delivered through the kernel's outbox: @kawa.digest@,
-- @kizashi.signal@, @rei.action@, @danwa.conversation@ and @channel.egress@.
-- Each adapter validates its configuration ("Shikigami.Sink.Outputs") when a
-- declaration loads, addresses an output when it is enqueued (the only time
-- the trigger activity is in scope), names the target the authority decides,
-- and dispatches through its service client. The adapters close over their
-- own endpoints and HTTP environment, so the kernel names no service.
-- @kawa.digest@ is the default output of a Kikan composition.
module Shikigami.Output.Kikan
  ( KikanServices (..),
    kikanOutputAdapters,
    kikanOutputs,
    kawaDigestAdapter,
    kizashiSignalAdapter,
    reiActionAdapter,
    danwaConversationAdapter,
    channelEgressAdapter,
    kawaDigestKind,
    defaultKawaDigest,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON, Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Activity.Coordinate (activityCoordinate, activityCoordinateText)
import Shikigami.Agent.DeclarationValue
import Shikigami.Authority (OutputKind, outputKindText)
import Shikigami.Log qualified as Log
import Shikigami.Output
import Shikigami.Sink.Config (DanwaConfig, KanmonConfig, KawaConfig, KizashiConfig, ReiConfig)
import Shikigami.Sink.Danwa (DanwaError (..), renderDanwaError, runDanwaWithHeaders)
import Shikigami.Sink.Http (HttpFailure, SinkHttp (..))
import Shikigami.Sink.Http qualified as Http
import Shikigami.Sink.KanmonClient (KanmonError (..), buildEgressRequest, postEgressWithHeaders, renderKanmonError, resolveConversationKey)
import Shikigami.Sink.KawaClient (KawaError (..), buildEnvelope, postEnvelopeWithHeaders, renderKawaError)
import Shikigami.Sink.KizashiClient (KizashiError (..), buildSignalReq, postSignalWithHeaders, renderKizashiError)
import Shikigami.Sink.Outputs
import Shikigami.Sink.Recipient (resolveRecipient, unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (runReiAction)
import Shikigami.Sink.Types
import Shikigami.Sink.Wire (EgressActionResponse (..), SignalResponse (..))

-- | The endpoints and clients the adapters close over.
data KikanServices = KikanServices
  { http :: !SinkHttp,
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    kanmon :: !KanmonConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig
  }

kikanOutputAdapters :: KikanServices -> [OutputAdapter]
kikanOutputAdapters services = ($ services) <$> [kawaDigestAdapter, kizashiSignalAdapter, reiActionAdapter, danwaConversationAdapter, channelEgressAdapter]

-- | The five adapters with no default output.
kikanOutputs :: KikanServices -> OutputRegistry
kikanOutputs services = either (error . Text.unpack) id (mkOutputRegistry (kikanOutputAdapters services) NoDefaultOutput)

-- | A Kikan composition's default output: an @agent-run@ subject @reported@.
defaultKawaDigest :: OutputDecl
defaultKawaDigest = kawaDigestOutput KawaDigestOutput {subjectType = activityCoordinate "agent-run", verb = activityCoordinate "reported"}

-- | An adapter whose configuration is @a@.
outboxAdapter ::
  forall a.
  (FromJSON a) =>
  OutputKind ->
  (a -> AddressInput -> Value) ->
  (a -> Value -> Either Text (NonEmpty Text)) ->
  (a -> OutboxDelivery -> IO SinkOutcome) ->
  OutputAdapter
outboxAdapter kind address target dispatch =
  OutputAdapter
    { kind,
      validate = \config -> case outputConfigErrors (OutputDecl kind config) of
        [] -> () <$ (decoded config :: Either Text a)
        problem : _ -> Left problem,
      route =
        DeliverByOutbox
          OutboxRoute
            { address = \input -> either (const Null) (\config -> address config input) (decoded input.config),
              target = \config addressed -> decoded config >>= \typed -> target typed addressed,
              dispatch = \delivery -> either (pure . PermanentFailure) (\typed -> dispatch typed delivery) (decoded delivery.config)
            }
    }
  where
    decoded :: (FromJSON b) => Value -> Either Text b
    decoded = decodeOutputConfig kind

noAddress :: a -> AddressInput -> Value
noAddress _ _ = Null

kawaDigestAdapter :: KikanServices -> OutputAdapter
kawaDigestAdapter services =
  outboxAdapter
    kawaDigestKind
    noAddress
    (\KawaDigestOutput {subjectType, verb} _ -> Right (activityCoordinateText subjectType :| [activityCoordinateText verb]))
    \config delivery ->
      buildEnvelope delivery config >>= \case
        Left err@KawaPayloadError {} -> pure (PermanentFailure (renderKawaError err))
        Left err -> pure (kawaFailure err)
        Right envelope -> either kawaFailure (Delivered . declarationCoordinate) <$> postEnvelopeWithHeaders services.http.kawa delivery.traceHeaders services.kawa envelope

kizashiSignalAdapter :: KikanServices -> OutputAdapter
kizashiSignalAdapter services =
  outboxAdapter
    kizashiSignalKind
    (\config AddressInput {activity} -> object ["recipient" .= (config.recipient <|> resolveRecipient config.recipientFrom activity)])
    ( \config addressed -> case addressedRecipient addressed <|> config.defaultRecipient of
        Nothing -> Left "Kizashi recipient was not resolved before authorization"
        Just recipient -> Right (declarationCoordinateText recipient :| [])
    )
    \config delivery -> do
      let resolved = addressedRecipient delivery.address
      -- A strategy that was declared and could not be honored is said out
      -- loud; the alternative is a signal quietly reaching whoever the
      -- fallback names.
      traverse_
        (\warning -> Log.logWarn delivery.logger "sink.recipient.unresolved" ["agent" .= deliverySubjectText delivery, Log.runIdKey .= delivery.runId, "sink_kind" .= outputKindText kizashiSignalKind, "detail" .= warning])
        (unresolvableRecipientWarning config resolved)
      case buildSignalReq services.kizashi resolved config delivery.identity delivery.result of
        Left problem -> pure (Failed problem)
        Right request -> either kizashiFailure (Delivered . declarationCoordinate . (.signalId)) <$> postSignalWithHeaders services.http.kizashi delivery.traceHeaders services.kizashi request

addressedRecipient :: Value -> Maybe (DeclarationCoordinate "recipient")
addressedRecipient = \case
  Object fields | Just value <- KeyMap.lookup "recipient" fields -> parseMaybe Aeson.parseJSON value
  _ -> Nothing

reiActionAdapter :: KikanServices -> OutputAdapter
reiActionAdapter services =
  outboxAdapter
    reiActionKind
    noAddress
    (\ReiActionOutput {intentionId} _ -> Right (declarationCoordinateText intentionId :| []))
    \config delivery -> either Failed (Delivered . declarationCoordinate) <$> runReiAction (Http.unauthenticatedHttpEnv services.http.kawa) services.rei delivery config

danwaConversationAdapter :: KikanServices -> OutputAdapter
danwaConversationAdapter services =
  outboxAdapter
    danwaConversationKind
    noAddress
    (\DanwaConversationOutput {topic, thread} _ -> Right (maybe topic (\DanwaTarget {conversationId} -> declarationCoordinateText conversationId) thread :| []))
    \config delivery ->
      either danwaFailure (Delivered . declarationCoordinate . declarationCoordinateText)
        <$> runDanwaWithHeaders services.http.danwa delivery.traceHeaders services.danwa delivery.identity delivery.receipts config delivery.result

channelEgressAdapter :: KikanServices -> OutputAdapter
channelEgressAdapter services =
  outboxAdapter
    channelEgressKind
    ( \ChannelEgressOutput {conversationKey} AddressInput {activity, result} ->
        object
          [ "conversationKey" .= resolveConversationKey conversationKey activity result,
            "triggeringActivityId" .= ((.activityId) <$> activity)
          ]
    )
    ( \ChannelEgressOutput {channel} addressed -> case addressedField "conversationKey" addressed of
        Nothing -> Left "channel conversation was not resolved before authorization"
        Just conversation -> Right (declarationCoordinateText channel :| [conversation])
    )
    \ChannelEgressOutput {channel, action} delivery ->
      case buildEgressRequest delivery (declarationCoordinate <$> addressedField "conversationKey" delivery.address) (parseField "triggeringActivityId" delivery.address) delivery.result of
        Left failure -> pure (PermanentFailure failure)
        Right request -> either kanmonFailure (Delivered . declarationCoordinate . (.activityId)) <$> postEgressWithHeaders services.http.kanmon delivery.traceHeaders services.kanmon channel action request
  where
    addressedField name = \case
      Object fields | Just (String value) <- KeyMap.lookup name fields -> Just value
      _ -> Nothing
    parseField name = \case
      Object fields | Just value <- KeyMap.lookup name fields -> parseMaybe Aeson.parseJSON value
      _ -> Nothing

kawaFailure :: KawaError -> SinkOutcome
kawaFailure failure = case failure of
  KawaPayloadError detail -> PermanentFailure detail
  KawaHttpError httpFailure -> classifiedFailure httpFailure
  KawaDecodeError _ -> PermanentFailure (renderKawaError failure)

kizashiFailure :: KizashiError -> SinkOutcome
kizashiFailure failure = case failure of
  KizashiHttpError httpFailure -> classifiedFailure httpFailure
  KizashiDecodeError _ -> PermanentFailure (renderKizashiError failure)

danwaFailure :: DanwaError -> SinkOutcome
danwaFailure failure = case failure of
  DanwaHttpError httpFailure -> classifiedFailure httpFailure
  DanwaReceiptFailure _ -> Failed (renderDanwaError failure)
  DanwaUsageError _ -> PermanentFailure (renderDanwaError failure)

kanmonFailure :: KanmonError -> SinkOutcome
kanmonFailure failure = case failure of
  KanmonHttpError httpFailure -> classifiedFailure httpFailure
  KanmonDecodeError _ -> PermanentFailure (renderKanmonError failure)
  KanmonUsageError _ -> PermanentFailure (renderKanmonError failure)

classifiedFailure :: HttpFailure -> SinkOutcome
classifiedFailure failure
  | Http.httpFailureIsPermanent failure = PermanentFailure (Http.renderHttpFailure failure)
  | otherwise = Failed (Http.renderHttpFailure failure)
