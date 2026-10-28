module Shikigami.Execution.Policy (validateTerminalOutput, module Shikigami.Execution.Policy.Types) where

import Baikai.StopReason (StopReason (ErrorReason, ToolUse))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Transcript
import Shikigami.Prelude

-- Output validation reads the accepted assistant, not a newly sampled answer.
-- The runner may admit an ordinary bounded repair after a refusal.
validateTerminalOutput :: HarnessPolicy -> ReplayAssistant -> Either ExecutionError Aeson.Value
validateTerminalOutput policy assistant = do
  unless (assistant.format == 1 && isNothing assistant.failure && assistant.stopReason `notElem` [ToolUse, ErrorReason] && null (toolInvocations assistant)) (Left ExecutionOutputInvalid)
  let reply = assistantText assistant
  case policy.output of
    AnyReply -> Right ()
    NonemptyReply -> unless (not (Text.null (Text.strip reply))) (Left ExecutionOutputInvalid)
    JsonFields fields -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 reply) of
      Right (Aeson.Object value) -> unless (all (\key -> KeyMap.member (Key.fromText key) value) fields) (Left ExecutionOutputInvalid)
      _ -> Left ExecutionOutputInvalid
  pure (Aeson.object ["reply" Aeson..= reply])
