-- | The pack's one configuration setting: the observer allowances. The key
-- and its environment variable are the ones the kernel declared before the
-- pack owned them. An executable composed with the pack accepts the key; a
-- stock executable refuses it as unknown.
module FlowPack.Initiative.Setting
  ( initiativesKey,
    initiativesSetting,
    initiativeSettingsFrom,
  )
where

import Data.Aeson (Result (..), fromJSON)
import Data.Text (Text)
import FlowPack.Initiative.Settings (InitiativeSettings)
import Shikigami.Pack.Sdk (PackSetting (..), PackSettings, SettingShape (..), packSettingValue)

initiativesKey :: Text
initiativesKey = "initiatives"

-- | The setting as an executable accepts it. Unset, nothing observes.
initiativesSetting :: PackSetting
initiativesSetting =
  PackSetting
    { key = initiativesKey,
      environment = "SHIKIGAMI_INITIATIVES",
      description = "Observer allowances: which principals may observe which sources, at what evaluation envelope and attention limits",
      expectation = "a structurally valid JSON value of the declared type",
      shape = JsonSetting,
      whenAbsent = Nothing,
      validate = \value -> case fromJSON value of
        Success (_ :: InitiativeSettings) -> Right ()
        Error _ -> Left "not observer allowances"
    }

-- | The typed settings of a run or a process. The value was decoded once at
-- start by the same instance, so a failure here can only be a value no
-- executable validated; it reads as unset.
initiativeSettingsFrom :: PackSettings -> Maybe InitiativeSettings
initiativeSettingsFrom settings = case fromJSON <$> packSettingValue initiativesKey settings of
  Just (Success configured) -> Just configured
  _ -> Nothing
