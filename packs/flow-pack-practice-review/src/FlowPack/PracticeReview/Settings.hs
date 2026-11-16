-- | The pack's one configuration setting: which Kizashi recipient hears about
-- an actionable review for which owner.
--
-- The key and its environment variable are the ones the kernel declared
-- before the pack owned them. An executable composed with the pack accepts
-- the key and validates it at start; a stock executable refuses it as unknown.
module FlowPack.PracticeReview.Settings
  ( attentionRecipientsSetting,
    attentionRecipientsKey,
    attentionRecipientsFrom,
  )
where

import Data.Functor (void)
import FlowPack.PracticeReview.Capability (AttentionRecipientMap, emptyAttentionRecipientMap, parseAttentionRecipientMap)
import Shikigami.Pack.Sdk (PackSetting (..), PackSettings, packSettingValue)
import Shikigami.Prelude (Text)

attentionRecipientsKey :: Text
attentionRecipientsKey = "practice_review.attention_recipients"

-- | Empty by default, which fails closed: an actionable review cannot reserve
-- attention until an operator maps every owner they expect to encounter. The
-- deployment-wide Kizashi fallback is not used.
attentionRecipientsSetting :: PackSetting
attentionRecipientsSetting =
  PackSetting
    { key = attentionRecipientsKey,
      environment = "SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS",
      description = "Comma-separated practice-review owner mappings (owner=recipient_id or sorted owner+owner=recipient_id)",
      expectation = "a comma-separated unique map of owner or sorted owner+owner keys to recipient_... ids",
      defaultRule = "practice-review-attention-unmapped",
      defaultReason = "Require operators to map every actionable review owner explicitly",
      defaultValue = "",
      validate = void . parseAttentionRecipientMap
    }

-- | The typed map of a run. The text was validated at start by the parser
-- used here, so a value that fails to parse can only be one no composed
-- executable validated; it is treated as unmapped, the fail-closed default.
attentionRecipientsFrom :: PackSettings -> AttentionRecipientMap
attentionRecipientsFrom settings =
  case parseAttentionRecipientMap <$> packSettingValue attentionRecipientsKey settings of
    Just (Right recipients) -> recipients
    _ -> emptyAttentionRecipientMap
