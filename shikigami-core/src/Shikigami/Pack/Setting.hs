-- | A configuration setting a flow pack owns (docs/adr/0129).
--
-- The kernel's configuration declaration is closed: an unknown key refuses to
-- start. A pack that needs a setting therefore declares it as a 'PackSetting',
-- and an executable composed with that pack accepts the key, binds its
-- environment variable, validates the value at start and hands the validated
-- value to the pack's interpreter in 'PackSettings'. A stock executable, which
-- composes no pack, keeps refusing the key as unknown.
--
-- The value crosses the boundary as JSON: a text setting is a JSON string, and
-- a structured setting is whatever the file, flag or variable supplied. The
-- pack owns the typed meaning and decodes it with the same parser its
-- 'validate' ran at start, so the kernel never learns a pack's vocabulary.
module Shikigami.Pack.Setting
  ( PackSetting (..),
    SettingShape (..),
    SettingDefault (..),
    PackSettings,
    noPackSettings,
    packSettingsFromList,
    packSettingsToList,
    packSettingValue,
    packSettingText,
  )
where

import Data.Aeson (Value (String))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

-- | How a source's raw value becomes the JSON a pack validates.
data SettingShape
  = -- | One scalar, taken as text: @owner=recipient,other=recipient@. The
    -- validator receives a JSON string.
    TextSetting
  | -- | A structured value: a mapping in a YAML file, or JSON text in a flag or
    -- an environment variable.
    JsonSetting
  deriving stock (Eq, Show)

-- | The value a setting takes when no source supplies one, with the rule name
-- and reason @--explain-config@ prints.
data SettingDefault = SettingDefault
  { rule :: !Text,
    reason :: !Text,
    value :: !Value
  }

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
    shape :: !SettingShape,
    -- | 'Nothing' leaves the key optional: unset, it is absent from
    -- 'PackSettings'. A pack setting is never required.
    whenAbsent :: !(Maybe SettingDefault),
    -- | Run at start; a 'Left' refuses to start (ADR-38).
    validate :: !(Value -> Either Text ())
  }

-- | The validated values of the composed packs' settings, by key. Opaque so
-- that a value can only arrive through the configuration loader or a test's
-- explicit 'packSettingsFromList'.
newtype PackSettings = PackSettings (Map Text Value)
  deriving stock (Eq, Show)

noPackSettings :: PackSettings
noPackSettings = PackSettings Map.empty

packSettingsFromList :: [(Text, Value)] -> PackSettings
packSettingsFromList = PackSettings . Map.fromList

packSettingsToList :: PackSettings -> [(Text, Value)]
packSettingsToList (PackSettings values) = Map.toAscList values

-- | The validated value of one key; 'Nothing' when no composed pack declared
-- it, or when it is optional and unset.
packSettingValue :: Text -> PackSettings -> Maybe Value
packSettingValue key (PackSettings values) = Map.lookup key values

-- | The value of a 'TextSetting'.
packSettingText :: Text -> PackSettings -> Maybe Text
packSettingText key settings = case packSettingValue key settings of
  Just (String text) -> Just text
  _ -> Nothing
