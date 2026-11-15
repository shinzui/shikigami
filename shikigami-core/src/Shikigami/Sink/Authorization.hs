{-# LANGUAGE DataKinds #-}

-- | Exact kernel 'EmitOutput' actions for fully-resolved sink dispatches.
--
-- Each sink is an output of a dotted kind (@kawa.digest@, @kizashi.signal@,
-- @rei.action@, @danwa.conversation@, @channel.egress@) delivered to a
-- resolved target. The composed authority decides the action; the Kikan-En
-- adapter maps it onto its own vocabulary.
module Shikigami.Sink.Authorization
  ( authorizeSinkAction,
    sinkOutputKind,
    sinkAction,
  )
where

import Control.Applicative ((<|>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Shikigami.Activity.Coordinate (activityCoordinateText)
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Authority
  ( Action (EmitOutput),
    Authority,
    AuthorityFailure (..),
    Decision,
    OutputKind,
    mkOutputKind,
    mkOutputTarget,
  )
import Shikigami.Sink.Types qualified as Sink

authorizeSinkAction ::
  Authority ->
  AgentIdentity ->
  Sink ->
  Maybe Sink.DanwaTarget ->
  Maybe (DeclarationCoordinate "recipient") ->
  Maybe (DeclarationCoordinate "conversation") ->
  IO (Either AuthorityFailure Decision)
authorizeSinkAction authorizer identity sink danwaTarget resolvedRecipient resolvedConversation =
  case identityText identity of
    Left problem -> pure (Left (InvalidCoordinates problem))
    Right principal ->
      case sinkAction sink danwaTarget resolvedRecipient resolvedConversation of
        Left problem -> pure (Left (InvalidCoordinates problem))
        Right action -> authorizer.decide (declarationCoordinate principal) action

-- | The output kind each sink constructor delivers through.
sinkOutputKind :: Sink -> OutputKind
sinkOutputKind sink =
  either (error . show) id . mkOutputKind $ case sink of
    KawaDigest {} -> "kawa.digest"
    KizashiSignal {} -> "kizashi.signal"
    ReiAction {} -> "rei.action"
    DanwaConversation {} -> "danwa.conversation"
    ChannelEgress {} -> "channel.egress"

sinkAction ::
  Sink ->
  Maybe Sink.DanwaTarget ->
  Maybe (DeclarationCoordinate "recipient") ->
  Maybe (DeclarationCoordinate "conversation") ->
  Either Text Action
sinkAction sink danwaTarget resolvedRecipient resolvedConversation =
  EmitOutput (sinkOutputKind sink) <$> (mkOutputTarget =<< segments)
  where
    segments = case sink of
      KawaDigest {subjectType, verb} -> Right (activityCoordinateText subjectType :| [activityCoordinateText verb])
      KizashiSignal {defaultRecipient} -> do
        recipient <- maybe (Left "Kizashi recipient was not resolved before authorization") Right (resolvedRecipient <|> defaultRecipient)
        Right (declarationCoordinateText recipient :| [])
      ReiAction {intentionId} -> Right (declarationCoordinateText intentionId :| [])
      DanwaConversation {topic} ->
        Right (maybe topic (\Sink.DanwaTarget {conversationId} -> declarationCoordinateText conversationId) danwaTarget :| [])
      ChannelEgress {channel} -> do
        conversation <- maybe (Left "channel conversation was not resolved before authorization") Right resolvedConversation
        Right (declarationCoordinateText channel :| [declarationCoordinateText conversation])
