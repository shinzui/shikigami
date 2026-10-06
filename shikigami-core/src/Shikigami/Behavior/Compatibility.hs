-- | Pure checks for requirements the selected Baikai surface can uphold.
-- Never alter a request to make it fit a weaker surface.
module Shikigami.Behavior.Compatibility
  ( ResponseCompatibilityError (..),
    validateResponseOptions,
    validateResponseRequest,
    renderResponseCompatibilityError,
  )
where

import Baikai.Api (Api (..))
import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat qualified as Compat
import Baikai.Context (Context, tools)
import Baikai.Header (renderHeaderName)
import Baikai.Model (Model)
import Baikai.Model qualified as Model
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Baikai.ResponseFormat (ResponseFormat (..))
import Baikai.Speed (Speed (..))
import Baikai.ThinkingLevel (thinkingTokenBudget)
import Baikai.Tool (ToolChoice (..))
import Baikai.Tool qualified as Tool
import Data.Aeson (Value (..))
import Data.Char (isAlphaNum, isAscii)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector

data ResponseCompatibilityError
  = UnsupportedOption !Text
  | UnsupportedTools
  | UnsupportedFormat
  | BatchCancellationReleaseRequired
  deriving stock (Eq, Show)

renderResponseCompatibilityError :: ResponseCompatibilityError -> Text
renderResponseCompatibilityError = \case
  UnsupportedOption key -> key <> " is unsupported by the selected provider/model or conflicts with another requirement"
  UnsupportedTools -> "CLI responses cannot execute advertised Shikumi tools"
  UnsupportedFormat -> "CLI responses cannot enforce JsonObject output"
  BatchCancellationReleaseRequired -> "CLI responses require a released Baikai adapter that cancels the entire child process group"

validateResponseOptions :: Model -> Options -> Either ResponseCompatibilityError ()
validateResponseOptions model options = case Model.api model of
  Custom _ -> Right ()
  AnthropicMessagesCli -> Left BatchCancellationReleaseRequired
  OpenAICompletionsCli -> Left BatchCancellationReleaseRequired
  api -> case unsupported api of
    key : _ -> Left (UnsupportedOption ("behavior.options." <> key))
    [] -> Right ()
  where
    set = isJust
    invalidRange lo hi = maybe False (\v -> isNaN v || isInfinite v || v < lo || v > hi)
    common =
      [ ("headers", any invalidHeader (Map.toList (Options.headers options))),
        ("max_tokens", maybe False (\cap -> cap == 0 || Model.maxOutputTokens model > 0 && cap > Model.maxOutputTokens model) (Options.maxTokens options)),
        ("timeout_ms", maybe False (\n -> n < 1 || n > 86_400_000) (Options.timeoutMs options)),
        ("temperature", invalidRange 0 2 (Options.temperature options)),
        ("top_p", invalidRange 0 1 (Options.topP options)),
        ("frequency_penalty", invalidRange (-2) 2 (Options.frequencyPenalty options)),
        ("presence_penalty", invalidRange (-2) 2 (Options.presencePenalty options)),
        ("thinking", set (Options.thinking options) && not (Model.reasoning model))
      ]
    sampling allowed =
      [("temperature", set (Options.temperature options) && not allowed), ("top_p", set (Options.topP options) && not allowed)]
    efforts allowed = [("thinking", maybe False (\requested -> maybe False (not . elem requested) allowed) (Options.thinking options))]
    penalties = [("seed", set (Options.seed options)), ("frequency_penalty", set (Options.frequencyPenalty options)), ("presence_penalty", set (Options.presencePenalty options))]
    retention = Options.cacheRetention options
    wantsCache = retention /= Nothing && retention /= Just CacheRetentionNone
    wantsLong = retention == Just CacheRetentionLong
    unsupported api = [key | (key, invalid) <- common <> specific api, invalid]
    specific AnthropicMessages =
      let compat = Model.anthropicMessagesCompatFor model
          budget = compat.thinkingStyle == Compat.AnthropicThinkingBudget && set (Options.thinking options)
       in penalties
            <> sampling (compat.supportsSamplingParameters)
            <> [ ("thinking", budget && maybe False (\level -> Model.maxOutputTokens model > 0 && Model.maxOutputTokens model <= thinkingTokenBudget level) (Options.thinking options)),
                 ("metadata", not (Map.null (Options.metadata options))),
                 ("cache_retention", wantsLong && not (compat.supportsLongCacheRetention)),
                 ("speed", Options.speed options == Just SpeedFast && not (compat.supportsFastMode)),
                 ("tool_choice", forced && (not (compat.supportsForcedToolChoice)))
               ]
    specific OpenAIChatCompletions =
      let compat = Model.openaiCompletionsCompatFor model
       in sampling (compat.supportsSamplingParameters)
            <> efforts (compat.supportedReasoningEfforts)
            <> [ ("speed", set (Options.speed options)),
                 ("metadata", not (Map.null (Options.metadata options))),
                 ("cache_retention", wantsCache && (not (set (compat.cacheControlFormat)) || wantsLong && not (compat.supportsLongCacheRetention)))
               ]
    specific OpenAIResponses =
      let compat = Model.openaiResponsesCompatFor model
       in penalties
            <> sampling (compat.supportsSamplingParameters)
            <> efforts (compat.supportedReasoningEfforts)
            <> [ ("speed", set (Options.speed options)),
                 ("stop_sequences", not (null (Options.stopSequences options))),
                 ("cache_retention", wantsLong && (compat.supportsPromptCacheOptions || not (compat.supportsLongCacheRetention))),
                 ("metadata", Map.size (Options.metadata options) > 16 || any ((> 64) . Text.length) (Map.keys (Options.metadata options)) || any invalidMetadata (Map.elems (Options.metadata options)))
               ]
    specific _ = []
    forced = case Options.toolChoice options of
      Just ToolChoiceRequired -> True
      Just ToolChoiceSpecific {} -> True
      _ -> False
    invalidHeader (name, value) =
      let text = renderHeaderName name
       in Text.null text || Text.any (\c -> not (isAscii c && (isAlphaNum c || c `elem` ("!#$%&'*+-.^_`|~" :: String)))) text || Text.any (\c -> c == '\r' || c == '\n') value
    invalidMetadata (String value) = Text.length value > 512
    invalidMetadata _ = True

validateResponseRequest :: Model -> Options -> Context -> Either ResponseCompatibilityError ()
validateResponseRequest model options context
  | cli && not (Vector.null context.tools) = Left UnsupportedTools
  | cli && Options.responseFormat options == Just JsonObject = Left UnsupportedFormat
  | otherwise = do
      validateResponseOptions model options
      case Options.toolChoice options of
        Just ToolChoiceRequired | Vector.null context.tools -> Left (UnsupportedOption "behavior.options.tool_choice")
        Just (ToolChoiceSpecific name) | not (Vector.any ((== name) . Tool.name) context.tools) -> Left (UnsupportedOption "behavior.options.tool_choice")
        _ -> Right ()
  where
    cli = Model.api model `elem` [AnthropicMessagesCli, OpenAICompletionsCli]
