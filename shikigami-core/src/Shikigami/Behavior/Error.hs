module Shikigami.Behavior.Error
  ( FailureClass (..),
    RunError (..),
    TransientBehaviorFailure (..),
    boundedBehaviorDetail,
    classifyRunError,
    renderRunError,
  )
where

import Control.Exception (Exception)
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | Whether retrying a behavior may succeed without changing its input.
data FailureClass = Transient | Permanent
  deriving stock (Eq, Show, Generic)

-- | Why a behavior run failed. Shared by the program arm (Shikigami.Behavior.Run),
-- the skill arm (Shikigami.Behavior.Skill), and the run-with-memory seam.
data RunError
  = -- | A ShikumiProgram named a task that is not in the registry.
    UnknownTask !Text
  | -- | The program rejected its deterministic argument map.
    ProgramInputFailed !Text
  | -- | handan/shikumi failed while running an already-parsed program.
    ProgramRuntimeFailed !Text
  | -- | SKILL.md was missing or its frontmatter was malformed.
    SkillLoadFailed !Text
  | -- | The baikai completion failed.
    SkillRunFailed !Text
  | -- | The provider reported a failure /in band/: baikai 0.4 returns an
    -- error-shaped 'Baikai.Response.Response' rather than throwing, so a caller
    -- that only reads the assistant text renders a provider outage as a
    -- successful empty reply. The flag is baikai's own
    -- 'Baikai.Error.isRetryable' — true for rate limits and transient server or
    -- network failures. What the worker does with it (retry ceiling,
    -- dead-lettering, honouring @retry_after@) is owned by
    -- @docs\/plans\/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md@;
    -- this constructor's job is to stop the failure from looking like an answer.
    ProviderFailed !Bool !Text
  | -- | A behavior arm not implemented by this plan (e.g. Deterministic, owned by EP-6).
    UnsupportedBehavior !Text
  deriving stock (Eq, Show, Generic)

-- | A retryable behavior failure that must escape a workflow step before Keiro
-- can append a result for that attempt.
data TransientBehaviorFailure = TransientBehaviorFailure
  { detail :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance Exception TransientBehaviorFailure

classifyRunError :: RunError -> FailureClass
classifyRunError = \case
  UnknownTask {} -> Permanent
  ProgramInputFailed {} -> Permanent
  ProgramRuntimeFailed {} -> Transient
  SkillLoadFailed {} -> Permanent
  SkillRunFailed {} -> Transient
  ProviderFailed retryable _ -> if retryable then Transient else Permanent
  UnsupportedBehavior {} -> Permanent

renderRunError :: RunError -> Text
renderRunError =
  boundedBehaviorDetail . \case
    UnknownTask task -> "unknown task: " <> task
    ProgramInputFailed err -> "program input failed: " <> err
    ProgramRuntimeFailed err -> "program runtime failed: " <> err
    SkillLoadFailed err -> "skill load failed: " <> err
    SkillRunFailed err -> "skill run failed: " <> err
    ProviderFailed _ err -> "provider failed: " <> err
    UnsupportedBehavior behavior -> "unsupported behavior: " <> behavior

-- | Keep journal and DLQ diagnostics single-line, bounded, and free of common
-- credential spellings. Diagnostics lose a suspicious token rather than risk
-- persisting a secret.
boundedBehaviorDetail :: Text -> Text
boundedBehaviorDetail = Text.take 512 . Text.unwords . redactWords . Text.words . Text.filter (not . isControl)
  where
    redactWords = \case
      [] -> []
      marker : _secret : rest
        | Text.toCaseFold marker `elem` sensitiveMarkers -> marker : "[redacted]" : redactWords rest
      word : rest -> redactInline word : redactWords rest

    sensitiveMarkers = ["authorization", "bearer", "password", "secret", "token", "api_key", "apikey"]

    redactInline word
      | any (`Text.isPrefixOf` Text.toCaseFold word) ["sk-", "xoxb-", "xoxp-"] = "[redacted]"
      | otherwise =
          case Text.breakOn "=" word of
            (key, value)
              | not (Text.null value) && Text.toCaseFold key `elem` sensitiveMarkers -> key <> "=[redacted]"
            _ -> word
