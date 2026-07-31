module Shikigami.Behavior.Error
  ( RunError (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Why a behavior run failed. Shared by the program arm (Shikigami.Behavior.Run),
-- the skill arm (Shikigami.Behavior.Skill), and the run-with-memory seam.
data RunError
  = -- | A ShikumiProgram named a task that is not in the registry.
    UnknownTask !Text
  | -- | handan/shikumi returned an error running the program.
    ProgramFailed !Text
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
