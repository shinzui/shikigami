{-# LANGUAGE DataKinds #-}

-- | Human-visible approval asks over Shikigami's authenticated outbound clients.
module Kikan.Shikigami.Binding.Approval
  ( kikanApprovalChannels,
    danwaChannel,
    kizashiChannel,
    danwaAsk,
    kizashiAsk,
    renderApprovalMessage,
  )
where

import Data.Aeson.Text (encodeToLazyText)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as LazyText
import Data.Time (nominalDiffTimeToSeconds)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText)
import Kikan.Shikigami.Binding.Output (KikanServices (..), loadKikanServices)
import Kikan.Shikigami.Binding.Output.Config (KizashiConfig (..))
import Kikan.Shikigami.Binding.Output.Danwa (DanwaError (..), postText, renderDanwaError)
import Kikan.Shikigami.Binding.Output.Http (KikanHttp (..))
import Kikan.Shikigami.Binding.Output.Kizashi (KizashiError (..), postSignal, renderKizashiError)
import Kikan.Shikigami.Binding.Output.Wire (CreateSignalReq (..))
import Kikan.Shikigami.Binding.Outputs (Priority (High), SignalType (AgentRequest), danwaApprovalChannel, kizashiApprovalChannel)
import Shikigami.Agent.Approval
  ( ApprovalChannel,
    ApprovalRequest (..),
    ReviewRequestId,
    reviewRequestIdText,
  )
import Shikigami.Agent.Approval.Workflow (ApprovalNotificationError (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Approval.Channel (ApprovalChannelAdapter (..), ApprovalChannelRegistration (..))
import Shikigami.Duration
import Shikigami.Prelude
import Shikigami.Sink.Http (httpFailureIsPermanent)

danwaChannel, kizashiChannel :: ApprovalChannel
danwaChannel = danwaApprovalChannel
kizashiChannel = kizashiApprovalChannel

-- | Asks go through Danwa unless @approval.channel=kizashi@. The opaque
-- awakeable token is sent only in the ask; structured logs retain the stable
-- review id instead.
kikanApprovalChannels :: [ApprovalChannelRegistration]
kikanApprovalChannels =
  [ ApprovalChannelRegistration {channel = danwaChannel, preferred = True, build = \context -> fmap danwaAsk <$> loadKikanServices context},
    ApprovalChannelRegistration {channel = kizashiChannel, preferred = False, build = \context -> fmap kizashiAsk <$> loadKikanServices context}
  ]

-- | Post the ask as a Danwa message.
danwaAsk :: KikanServices -> ApprovalChannelAdapter
danwaAsk services = ApprovalChannelAdapter \reviewId awakeableId deadline request ->
  (() <$) . first classifyDanwa <$> postText services.http.danwa services.danwa (renderApprovalMessage reviewId awakeableId deadline request)

-- | Post the ask as a Kizashi agent request to the default recipient.
kizashiAsk :: KikanServices -> ApprovalChannelAdapter
kizashiAsk services = ApprovalChannelAdapter \reviewId awakeableId deadline request ->
  (() <$) . first classifyKizashi
    <$> postSignal
      services.http.kizashi
      services.kizashi
      CreateSignalReq
        { actor = "shikigami",
          recipient = declarationCoordinateText services.kizashi.defaultRecipient,
          source = "shinzui/shikigami",
          signalType = AgentRequest,
          intent = renderApprovalMessage reviewId awakeableId deadline request,
          priority = High,
          importance = 100,
          contextTags = [reviewRequestIdText reviewId]
        }

-- | Render one bounded ask. Context is compact JSON and both caller-controlled
-- text fields are truncated so the transport request remains predictable even
-- when a behavior returns a very large value.
renderApprovalMessage :: ReviewRequestId -> AwakeableId -> Duration "approval" -> ApprovalRequest -> Text
renderApprovalMessage reviewId awakeableId deadline ApprovalRequest {prompt, context} =
  Text.intercalate
    "\n"
    [ "Approval required",
      "Review: " <> reviewRequestIdText reviewId,
      "Prompt: " <> bounded 1_000 prompt,
      "Context: " <> bounded 2_000 (LazyText.toStrict (encodeToLazyText context)),
      "Deadline: " <> Text.pack (show (floor (nominalDiffTimeToSeconds (durationTime deadline)) :: Integer)) <> " seconds",
      "Approve: shikigami resolve-approval " <> token <> " --approve",
      "Reject: shikigami resolve-approval " <> token <> " --reject \"reason\""
    ]
  where
    token = awakeableIdText awakeableId

bounded :: Int -> Text -> Text
bounded limit value
  | Text.length value <= limit = value
  | otherwise = Text.take limit value <> "…"

classifyDanwa :: DanwaError -> ApprovalNotificationError
classifyDanwa failure = case failure of
  DanwaHttpError httpFailure
    | httpFailureIsPermanent httpFailure -> PermanentNotification (renderDanwaError failure)
    | otherwise -> TransientNotification (renderDanwaError failure)
  DanwaReceiptFailure _ -> PermanentNotification "danwa receipt failure"
  DanwaUsageError _ -> PermanentNotification "danwa usage failure"

classifyKizashi :: KizashiError -> ApprovalNotificationError
classifyKizashi failure = case failure of
  KizashiHttpError httpFailure
    | httpFailureIsPermanent httpFailure -> PermanentNotification (renderKizashiError failure)
    | otherwise -> TransientNotification (renderKizashiError failure)
  KizashiDecodeError _ -> PermanentNotification "kizashi response decode failure"
