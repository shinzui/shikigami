-- | The pack's one configuration setting: the operator's read policy. The
-- key and its environment variable are the ones the kernel declared before
-- the pack owned them. An executable composed with the pack accepts the key;
-- a stock executable refuses it as unknown.
module FlowPack.Watchdog.Setting (watchdogKey, watchdogSetting, watchdogSettingsFrom) where

import Data.Aeson (Result (..), fromJSON)
import Data.Text (Text)
import FlowPack.Watchdog.Settings (WatchdogSettings)
import Shikigami.Pack.Sdk (PackSetting (..), PackSettings, SettingShape (..), packSettingValue)

-- | The key of the one configuration setting, as a pack setting: the key and
-- variable the kernel declared before the use case owned them. An executable
-- composed with the use case accepts the key; any other refuses it as unknown.
watchdogKey :: Text
watchdogKey = "watchdog"

-- | The setting as an executable accepts it. Unset, nothing is observed.
watchdogSetting :: PackSetting
watchdogSetting =
  PackSetting
    { key = watchdogKey,
      environment = "SHIKIGAMI_WATCHDOG",
      description = "Read-only active work observation: exact principal, scope, windows and bounded sweep size",
      expectation = "a structurally valid JSON value of the declared type",
      shape = JsonSetting,
      whenAbsent = Nothing,
      validate = \value -> case fromJSON value of
        Success (_ :: WatchdogSettings) -> Right ()
        Error _ -> Left "not a watchdog policy"
    }

-- | The typed settings of a run or a process. The value was decoded once at
-- start by the same instance, so a failure here can only be a value no
-- executable validated; it reads as unset.
watchdogSettingsFrom :: PackSettings -> Maybe WatchdogSettings
watchdogSettingsFrom settings = case fromJSON <$> packSettingValue watchdogKey settings of
  Just (Success configured) -> Just configured
  _ -> Nothing
