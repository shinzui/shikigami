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
  | -- | A behavior arm not implemented by this plan (e.g. Deterministic, owned by EP-6).
    UnsupportedBehavior !Text
  deriving stock (Eq, Show, Generic)
