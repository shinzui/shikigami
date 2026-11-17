{-# LANGUAGE DataKinds #-}

-- | The Kikan services' endpoint and credential settings (plan 135, M3).
--
-- They keep the keys and environment variables they had as kernel settings,
-- so an operator's configuration keeps working with the distribution's
-- executables; a stock executable, which composes no binding, refuses them as
-- unknown. The four tokens are secret pack settings: never displayed, read
-- only here.
module Kikan.Shikigami.Binding.Settings
  ( serviceSettings,
    ServiceEndpoints (..),
    loadServiceEndpoints,
    kawaSourceKey,
  )
where

import Data.Aeson (Value (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Output.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Pack.Sdk (PackSecret, PackSetting (..), PackSettings, SettingDefault (..), SettingShape (..), packSettingSecret, packSettingText)

kawaBaseUrlKey, kawaSourceKey, kizashiBaseUrlKey, kizashiRecipientKey, kanmonBaseUrlKey, danwaBaseUrlKey, danwaParticipantKey, reiBaseUrlKey :: Text
kawaBaseUrlKey = "sinks.kawa.base_url"
kawaSourceKey = "sinks.kawa.source_segment"
kizashiBaseUrlKey = "sinks.kizashi.base_url"
kizashiRecipientKey = "sinks.kizashi.default_recipient"
kanmonBaseUrlKey = "sinks.kanmon.base_url"
danwaBaseUrlKey = "sinks.danwa.base_url"
danwaParticipantKey = "sinks.danwa.agent_participant"
reiBaseUrlKey = "sinks.rei.base_url"

kawaTokenKey, kizashiTokenKey, kanmonTokenKey, danwaTokenKey :: Text
kawaTokenKey = "credentials.sinks.kawa.token"
kizashiTokenKey = "credentials.sinks.kizashi.token"
kanmonTokenKey = "credentials.sinks.kanmon.token"
danwaTokenKey = "credentials.sinks.danwa.token"

serviceSettings :: [PackSetting]
serviceSettings =
  [ text kawaBaseUrlKey "SHIKIGAMI_SINKS_KAWA_BASE_URL" "Base URL of the kawa ingest doorway" "a base URL" (Just ("local-kawa", "The local kawa (or stub-kawa) doorway", "http://localhost:8088")),
    text kawaSourceKey "SHIKIGAMI_SINKS_KAWA_SOURCE_SEGMENT" "Source segment kawa attributes ingested activity to" "a non-empty source segment" (Just ("kawa-source", "This repository's ingest source segment", "shinzui/shikigami")),
    text kizashiBaseUrlKey "SHIKIGAMI_SINKS_KIZASHI_BASE_URL" "Base URL of the kizashi signal service" "a base URL" (Just ("local-kizashi", "The local kizashi service", "http://localhost:8089")),
    text kizashiRecipientKey "SHIKIGAMI_SINKS_KIZASHI_DEFAULT_RECIPIENT" "Recipient used when a signal declares none" "a non-empty recipient" (Just ("kizashi-recipient", "Recipient used when a signal declares none", "recipient_default")),
    text kanmonBaseUrlKey "SHIKIGAMI_SINKS_KANMON_BASE_URL" "Base URL of the Kanmon channel-action service" "a base URL" (Just ("local-kanmon", "The local Kanmon channel-action service", "http://localhost:8090")),
    text danwaBaseUrlKey "SHIKIGAMI_SINKS_DANWA_BASE_URL" "Base URL of the danwa conversation server" "a base URL" (Just ("local-danwa", "The local danwa server", "http://localhost:8080")),
    text danwaParticipantKey "SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT" "danwa participant id Shikigami authors messages as" "a non-empty participant id" (Just ("danwa-agent", "Participant id Shikigami authors messages as", "part_shikigami")),
    text reiBaseUrlKey "SHIKIGAMI_SINKS_REI_BASE_URL" "Base URL of a rei ingestion endpoint; unset means rei.action outputs fail visibly rather than silently" "a base URL" Nothing,
    secret kawaTokenKey "SHIKIGAMI_KAWA_TOKEN" "Bearer token for the kawa output",
    secret kizashiTokenKey "SHIKIGAMI_KIZASHI_TOKEN" "Bearer token for the kizashi output",
    secret kanmonTokenKey "SHIKIGAMI_KANMON_TOKEN" "Bearer token authenticating Shikigami to Kanmon",
    secret danwaTokenKey "SHIKIGAMI_DANWA_TOKEN" "Bearer token for the danwa output and approval channel"
  ]
  where
    text key environment description expectation fallback =
      PackSetting
        { key,
          environment,
          description,
          expectation,
          shape = TextSetting,
          whenAbsent = (\(rule, reason, value) -> SettingDefault {rule, reason, value = String value}) <$> fallback,
          validate = nonEmpty expectation
        }
    secret key environment description =
      PackSetting
        { key,
          environment,
          description,
          expectation = "a non-empty token",
          shape = SecretTextSetting,
          whenAbsent = Nothing,
          validate = nonEmpty "a non-empty token"
        }
    nonEmpty expectation = \case
      String value | not (Text.null (Text.strip value)) -> Right ()
      _ -> Left expectation

-- | What the adapters and channels are configured with.
data ServiceEndpoints = ServiceEndpoints
  { kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    kanmon :: !KanmonConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    -- | Credentials, never displayed: read with 'packSecretToken'.
    kawaToken :: !(Maybe PackSecret),
    kizashiToken :: !(Maybe PackSecret),
    kanmonToken :: !(Maybe PackSecret),
    danwaToken :: !(Maybe PackSecret)
  }

-- | The validated settings. Every key with a default has a value; a missing
-- one is the composition's error, reported by name.
loadServiceEndpoints :: PackSettings -> Either Text ServiceEndpoints
loadServiceEndpoints settings = do
  kawaBase <- required kawaBaseUrlKey
  kawaSource <- required kawaSourceKey
  kizashiBase <- required kizashiBaseUrlKey
  kizashiRecipient <- required kizashiRecipientKey
  kanmonBase <- required kanmonBaseUrlKey
  danwaBase <- required danwaBaseUrlKey
  danwaParticipant <- required danwaParticipantKey
  pure
    ServiceEndpoints
      { kizashi = KizashiConfig {baseUrl = kizashiBase, defaultRecipient = declarationCoordinate kizashiRecipient},
        kawa = KawaConfig {baseUrl = kawaBase, sourceSegment = activityCoordinate kawaSource},
        kanmon = KanmonConfig {baseUrl = kanmonBase},
        danwa = DanwaConfig {baseUrl = danwaBase, agentParticipant = declarationCoordinate danwaParticipant},
        rei = ReiConfig {baseUrl = packSettingText reiBaseUrlKey settings},
        kawaToken = token kawaTokenKey,
        kizashiToken = token kizashiTokenKey,
        kanmonToken = token kanmonTokenKey,
        danwaToken = token danwaTokenKey
      }
  where
    required key = maybe (Left ("the Kikan binding needs " <> key)) Right (packSettingText key settings)
    token key = packSettingSecret key settings
