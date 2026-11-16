-- | A configuration setting a flow pack owns (docs/adr/0129).
--
-- The kernel's configuration declaration is closed: an unknown key refuses to
-- start. A pack that needs a setting therefore declares it as a 'PackSetting',
-- and an executable composed with that pack accepts the key, binds its
-- environment variable, validates the value at start and hands the validated
-- text to the pack's interpreter in 'PackSettings'. A stock executable, which
-- composes no pack, keeps refusing the key as unknown.
--
-- The value crosses the boundary as text. The pack owns the typed meaning and
-- decodes it with the same parser its 'validate' ran at start, so the kernel
-- never learns a pack's vocabulary.
module Shikigami.Pack.Setting
  ( PackSetting (..),
    PackSettings,
    noPackSettings,
    packSettingsFromList,
    packSettingsToList,
    packSettingValue,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

-- | One setting. Every field is operator-facing: the key and the variable are
-- what an operator writes, and the remaining text is what @--describe-config@,
-- @--explain-config@ and a refusal print.
data PackSetting = PackSetting
  { -- | The dotted configuration key, e.g. @practice_review.attention_recipients@.
    key :: !Text,
    -- | The environment variable bound to the key.
    environment :: !Text,
    description :: !Text,
    -- | What a valid value looks like; a refusal prints this and never the value.
    expectation :: !Text,
    -- | The name and reason of the rule that supplies 'defaultValue'.
    defaultRule :: !Text,
    defaultReason :: !Text,
    defaultValue :: !Text,
    -- | Run at start; a 'Left' refuses to start (ADR-38).
    validate :: !(Text -> Either Text ())
  }

-- | The validated values of the composed packs' settings, by key. Opaque so
-- that a value can only arrive through the configuration loader or a test's
-- explicit 'packSettingsFromList'.
newtype PackSettings = PackSettings (Map Text Text)
  deriving stock (Eq, Show)

noPackSettings :: PackSettings
noPackSettings = PackSettings Map.empty

packSettingsFromList :: [(Text, Text)] -> PackSettings
packSettingsFromList = PackSettings . Map.fromList

packSettingsToList :: PackSettings -> [(Text, Text)]
packSettingsToList (PackSettings values) = Map.toAscList values

-- | The validated value of one key; 'Nothing' when no composed pack declared it.
packSettingValue :: Text -> PackSettings -> Maybe Text
packSettingValue key (PackSettings values) = Map.lookup key values
