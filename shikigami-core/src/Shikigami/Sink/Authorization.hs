-- | Exact C13 target derivation for fully-resolved sink dispatches.
module Shikigami.Sink.Authorization
  ( authorizeSinkAction,
  )
where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Time (UTCTime)
import Kikan.En.Action
  ( AgentAction (..),
    AutonomyLevel (ActAutonomy),
    actionValueErrorText,
    mkAutonomyContext,
    mkChannelTarget,
    mkDanwaTarget,
    mkIntentionTarget,
    mkKawaTarget,
    mkKizashiTarget,
  )
import Shikigami.Action.Authorization
  ( ActionAuthorizationDecision,
    ActionAuthorizationFailure (..),
    ActionAuthorizer (..),
  )
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Sink.Types qualified as Sink

authorizeSinkAction ::
  ActionAuthorizer ->
  AgentIdentity ->
  Sink ->
  Maybe Sink.DanwaTarget ->
  Maybe Text ->
  Maybe Text ->
  UTCTime ->
  IO (Either ActionAuthorizationFailure ActionAuthorizationDecision)
authorizeSinkAction authorizer@ActionAuthorizer {authorize} identity sink danwaTarget resolvedRecipient resolvedConversation now =
  case identityText identity of
    Left problem -> pure (Left (ActionCoordinatesInvalid problem))
    Right principal ->
      case sinkAction authorizer sink danwaTarget resolvedRecipient resolvedConversation now of
        Left problem -> pure (Left (ActionCoordinatesInvalid problem))
        Right action -> authorize principal action

sinkAction ::
  ActionAuthorizer ->
  Sink ->
  Maybe Sink.DanwaTarget ->
  Maybe Text ->
  Maybe Text ->
  UTCTime ->
  Either Text AgentAction
sinkAction ActionAuthorizer {kawaSource} sink danwaTarget resolvedRecipient resolvedConversation now =
  case sink of
    KawaDigest {} -> DispatchKawa <$> firstValue (mkKawaTarget kawaSource)
    KizashiSignal {defaultRecipient} -> do
      recipient <- maybe (Left "Kizashi recipient was not resolved before authorization") Right (resolvedRecipient <|> (declarationCoordinateText <$> defaultRecipient))
      DispatchKizashi <$> firstValue (mkKizashiTarget recipient)
    ReiAction {intentionId} ->
      ActOnIntention
        <$> firstValue (mkIntentionTarget (declarationCoordinateText intentionId))
        <*> pure (mkAutonomyContext ActAutonomy now)
    DanwaConversation {topic} ->
      let targetText = maybe topic (\Sink.DanwaTarget {conversationId} -> conversationId) danwaTarget
       in AttachDanwa <$> firstValue (mkDanwaTarget targetText)
    ChannelEgress {channel} -> do
      conversation <- maybe (Left "channel conversation was not resolved before authorization") Right resolvedConversation
      DispatchChannel <$> firstValue (mkChannelTarget (declarationCoordinateText channel) conversation)
  where
    firstValue = either (Left . actionValueErrorText) Right
