-- | The operator's view of an agent run's coding-agent step: the child's
-- journaled outcome, read from the parent's journal (@child:<id>:result@).
module Shikigami.CodingAgent.Inspect (codingAgentInspection) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.CodingAgent.Types

-- | The coding-agent outcome a parent's step index records, if any.
codingAgentInspection :: Map Text Value -> Maybe Value
codingAgentInspection steps =
  case [(key, value) | (key, value) <- Map.toList steps, "child:" `Text.isPrefixOf` key, ":coding-agent:" `Text.isInfixOf` key, ":result" `Text.isSuffixOf` key] of
    [] -> Nothing
    (key, value) : _ ->
      let child = Text.dropEnd (Text.length ":result") (Text.drop (Text.length "child:") key)
       in Just case resultOf value of
            Nothing -> object ["child" .= child, "outcome" .= ("unreadable" :: Text)]
            Just outcome -> describe child outcome
  where
    resultOf = \case
      Object fields | Just ok <- KeyMap.lookup "ok" fields -> decoded ok
      other -> decoded other
    decoded value = case Aeson.fromJSON value of
      Aeson.Success outcome -> Just (outcome :: CodingAgentOutcome)
      Aeson.Error _ -> Nothing
    describe child outcome =
      object
        ( ["child" .= child, "outcome" .= outcomeLabel outcome, "summary" .= renderOutcome outcome]
            <> case outcome of
              Completed CompletedRun {exit, changes, result, finalMessage, evidence} ->
                [ "exitCode" .= exit,
                  "commit" .= case result of
                    Committed commit -> commit
                    Unchanged base -> base,
                  "committed" .= case result of
                    Committed _ -> True
                    Unchanged _ -> False,
                  "changedFiles" .= changes.files,
                  "omittedFiles" .= changes.omitted,
                  "finalMessage" .= Text.take 2048 finalMessage,
                  "evidence" .= evidence
                ]
              TimedOut PartialRun {uncommitted, evidence} -> ["uncommitted" .= uncommitted.files, "evidence" .= evidence]
              Uncertain UncertainRun {reason, uncommitted, launcherPid} -> ["reason" .= reason, "uncommitted" .= uncommitted.files, "launcherPid" .= launcherPid]
              Failed reason -> ["reason" .= reason]
        )
