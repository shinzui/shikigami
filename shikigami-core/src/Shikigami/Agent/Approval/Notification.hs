{-# LANGUAGE DataKinds #-}

-- | Human-visible approval asks over Shikigami's authenticated outbound clients.
module Shikigami.Agent.Approval.Notification
  ( approvalNotifier,
    renderApprovalMessage,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as LazyText
import Data.Time (nominalDiffTimeToSeconds)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText)
import Kioku.Id (idText)
import Shikigami.Agent.Approval
  ( ApprovalChannel (..),
    ApprovalRequest (..),
    ReviewRequestId,
    reviewRequestIdText,
  )
import Shikigami.Agent.Approval.Workflow
  ( ApprovalNotificationError (..),
    ApprovalNotifier (..),
  )
import Shikigami.Agent.Decl (Priority (High), SignalType (AgentRequest))
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Duration
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import Shikigami.Sink.Config (DanwaConfig, KizashiConfig (..))
import Shikigami.Sink.Danwa (DanwaError (..), postText, renderDanwaError)
import Shikigami.Sink.Http (SinkHttp (..), httpFailureIsPermanent)
import Shikigami.Sink.KizashiClient (KizashiError (..), postSignal, renderKizashiError)
import Shikigami.Sink.Wire (CreateSignalReq (..))

-- | Close the durable notification seam over process-lifetime clients. The
-- opaque awakeable token is sent only in the ask; structured logs retain the
-- stable review id instead.
approvalNotifier :: Log.Logger -> SinkHttp -> DanwaConfig -> KizashiConfig -> ApprovalNotifier
approvalNotifier logger SinkHttp {danwa = danwaClient, kizashi = kizashiHttp} danwaConfig kizashiConfig =
  ApprovalNotifier
    { recordPark = \session reviewId _awakeableId request ->
        Log.logInfo
          logger
          "approval.request.parked"
          [ "review_request_id" .= reviewRequestIdText reviewId,
            "session_id" .= idText session,
            "channel" .= renderChannel ((.channel) request)
          ],
      postAsk = \reviewId awakeableId deadline request -> do
        let message = renderApprovalMessage reviewId awakeableId deadline request
        result <- case (.channel) request of
          ViaDanwa -> (() <$) . first classifyDanwa <$> postText danwaClient danwaConfig message
          ViaKizashi ->
            (() <$) . first classifyKizashi
              <$> postSignal
                kizashiHttp
                kizashiConfig
                CreateSignalReq
                  { actor = "shikigami",
                    recipient = declarationCoordinateText ((.defaultRecipient) kizashiConfig),
                    source = "shinzui/shikigami",
                    signalType = AgentRequest,
                    intent = message,
                    priority = High,
                    importance = 100,
                    contextTags = [reviewRequestIdText reviewId]
                  }
        pure result
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

renderChannel :: ApprovalChannel -> Text
renderChannel = \case
  ViaDanwa -> "danwa"
  ViaKizashi -> "kizashi"

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
