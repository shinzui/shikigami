-- | Approval channels a pack registers (plan 135, M3).
--
-- The kernel owns the approval workflow and its one channel, the local
-- inbox. A pack that can reach people (the Kikan binding's Danwa and Kizashi)
-- registers a channel by name. A composition builds the registered channels
-- at start and asks through the one an ask names; an ask that names
-- 'configuredApprovalChannel' goes to the composition's configured channel.
module Shikigami.Approval.Channel
  ( ApprovalChannelAdapter (..),
    ApprovalChannelRegistration (..),
    chooseApprovalChannel,
    composeApprovalNotifier,
    buildApprovalChannels,
  )
where

import Data.Aeson ((.=))
import Data.List (find)
import Data.Text (Text)
import Keiro.Workflow.Awakeable (AwakeableId)
import Kioku.Id (idText)
import Shikigami.Agent.Approval
  ( ApprovalChannel,
    ApprovalRequest (..),
    ReviewRequestId,
    approvalChannelText,
    configuredApprovalChannel,
    localInboxChannel,
    reviewRequestIdText,
  )
import Shikigami.Agent.Approval.Workflow (ApprovalNotificationError (..), ApprovalNotifier (..))
import Shikigami.Duration (Duration)
import Shikigami.Log qualified as Log
import Shikigami.Output.Registration (AdapterContext)

-- | One way to post an ask.
newtype ApprovalChannelAdapter = ApprovalChannelAdapter
  { postAsk :: ReviewRequestId -> AwakeableId -> Duration "approval" -> ApprovalRequest -> IO (Either ApprovalNotificationError ())
  }

data ApprovalChannelRegistration = ApprovalChannelRegistration
  { channel :: !ApprovalChannel,
    -- | Whether a composition that names no channel takes this one.
    preferred :: !Bool,
    build :: !(AdapterContext -> IO (Either Text ApprovalChannelAdapter))
  }

-- | The composition's channel: the configured one when it is registered
-- (or is the local inbox), else the one a composed pack prefers, else the
-- local inbox.
chooseApprovalChannel :: [ApprovalChannelRegistration] -> Maybe ApprovalChannel -> Either Text ApprovalChannel
chooseApprovalChannel registrations = \case
  Just named
    | named == localInboxChannel -> Right named
    | any (\registration -> registration.channel == named) registrations -> Right named
    | otherwise ->
        Left
          ( "approval.channel "
              <> approvalChannelText named
              <> " is not composed here (composed: "
              <> mconcat (zipWith (<>) ("" : repeat ", ") (approvalChannelText <$> (localInboxChannel : [registration.channel | registration <- registrations])))
              <> ")"
          )
  Nothing -> case [registration.channel | registration <- registrations, registration.preferred] of
    [] -> Right localInboxChannel
    [preferredChannel] -> Right preferredChannel
    _ -> Left "more than one composed pack prefers its approval channel"

buildApprovalChannels :: AdapterContext -> [ApprovalChannelRegistration] -> IO (Either Text [(ApprovalChannel, ApprovalChannelAdapter)])
buildApprovalChannels context registrations =
  fmap sequence (traverse (\registration -> fmap (registration.channel,) <$> registration.build context) registrations)

-- | One notifier over the built channels. @configured@ answers an ask that
-- names 'configuredApprovalChannel'; @localInbox@ is the kernel's own channel
-- when the composition has a local inbox.
composeApprovalNotifier :: Log.Logger -> ApprovalChannel -> Maybe ApprovalChannelAdapter -> [(ApprovalChannel, ApprovalChannelAdapter)] -> ApprovalNotifier
composeApprovalNotifier logger configured localInbox channels =
  ApprovalNotifier
    { recordPark = \session reviewId _awakeableId request ->
        Log.logInfo
          logger
          "approval.request.parked"
          [ "review_request_id" .= reviewRequestIdText reviewId,
            "session_id" .= idText session,
            "channel" .= approvalChannelText (resolve request.channel)
          ],
      postAsk = \reviewId awakeableId deadline request ->
        case adapterFor (resolve request.channel) of
          Just adapter -> adapter.postAsk reviewId awakeableId deadline request
          Nothing -> pure (Left (PermanentNotification ("approval channel " <> approvalChannelText (resolve request.channel) <> " is not composed here")))
    }
  where
    resolve requested = if requested == configuredApprovalChannel then configured else requested
    adapterFor named
      | named == localInboxChannel = localInbox
      | otherwise = snd <$> find ((== named) . fst) channels
