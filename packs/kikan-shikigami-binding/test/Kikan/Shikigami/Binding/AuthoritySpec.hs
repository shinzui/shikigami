-- | The Kikan-En authority: the one place the kernel's action vocabulary
-- meets Kikan-En's, and the settings it is built from.
module Kikan.Shikigami.Binding.AuthoritySpec (tests) where

import Data.Aeson (Value (String))
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Kikan.En.Action qualified as Kikan
import Kikan.Shikigami.Binding.Authority
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Authority
import Shikigami.Pack.Setting (PackSetting (..), SettingShape (..), packSettingsWithSecrets)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Kikan-En authority" [kikanMappingTests, settingTests]

connect :: Action
connect = either (error . Text.unpack) id (connectProviderAction "workspace.read" "v1")

invoke :: Action
invoke = either (error . Text.unpack) id (invokeToolAction "shikigami.workspace" "1" "admit-sha256-abc")

output :: Text -> NonEmpty Text -> Action
output kind segments =
  either (error . Text.unpack) id (EmitOutput <$> mkOutputKind kind <*> mkOutputTarget segments)

launch :: Action
launch = either (error . Text.unpack) LaunchCodingAgent (mkCodingAgentTarget "claude" "edit" "mori://shinzui/fsrs-hs")

kikanMappingTests :: TestTree
kikanMappingTests =
  testGroup
    "Kikan-En mapping"
    [ -- toAgentAction is the one place the two vocabularies meet, so every
      -- constructor of the kernel's Action is decided here, mapped or not.
      testCase "every kernel action constructor has a decided mapping" do
        let decided = \case
              UseCapability ConnectProvider _ -> isRight' (mapped connect)
              UseCapability (InvokeTool _) _ -> isRight' (mapped invoke)
              EmitOutput {} -> isRight' (mapped (output "kizashi.signal" ("person-nadeem" :| [])))
              LaunchCodingAgent {} -> case mapped launch of
                Left NoKikanAction {} -> True
                _ -> False
        assertBool "connect" (decided connect)
        assertBool "invoke" (decided invoke)
        assertBool "emit" (decided (output "kizashi.signal" ("person-nadeem" :| [])))
        assertBool "a coding-agent launch is refused until Kikan-En names it" (decided launch),
      testCase "capability operations map one to one" do
        fmap Kikan.actionTag (mapped connect) @?= Right "connect_capability"
        fmap Kikan.actionTag (mapped invoke) @?= Right "invoke_capability_tool"
        fmap (Kikan.canonicalResourceText . Kikan.actionResource) (mapped invoke) @?= Right "capability_tool:shikigami.workspace@1/admit-sha256-abc",
      testCase "each Kikan output kind maps to its action" do
        fmap Kikan.actionTag (mapped (output "kawa.digest" ("ticket" :| ["ticket.received"]))) @?= Right "dispatch_kawa"
        fmap (Kikan.canonicalResourceText . Kikan.actionResource) (mapped (output "kawa.digest" ("ticket" :| ["ticket.received"]))) @?= Right "kawa_source:shinzui/shikigami"
        fmap Kikan.actionTag (mapped (output "kizashi.signal" ("person-nadeem" :| []))) @?= Right "dispatch_kizashi"
        fmap Kikan.actionTag (mapped (output "rei.action" ("intention_1" :| []))) @?= Right "act_on_intention"
        fmap Kikan.actionTag (mapped (output "danwa.conversation" ("thread-1" :| []))) @?= Right "attach_danwa"
        fmap Kikan.actionTag (mapped (output "channel.egress" ("slack" :| ["C123"]))) @?= Right "dispatch_channel",
      testCase "an output Kikan-En has no action for is unmapped, never substituted" do
        case mapped (output "local.report" ("report" :| [])) of
          Left NoKikanAction {} -> pure ()
          other -> assertFailure ("expected NoKikanAction, got " <> show other)
        case mapped (output "channel.egress" ("slack" :| [])) of
          Left NoKikanAction {} -> pure ()
          other -> assertFailure ("a malformed channel target must not map: " <> show other),
      testCase "a target Kikan-En rejects is an invalid target" do
        case mapped (output "kizashi.signal" ("person:nadeem" :| [])) of
          Left InvalidKikanTarget {} -> pure ()
          other -> assertFailure ("expected InvalidKikanTarget, got " <> show other)
    ]
  where
    mapped = toAgentAction KikanEnMapping {kawaSource = activityCoordinate "shinzui/shikigami"} (UTCTime (fromGregorian 2026 11 15) 0)

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

settingTests :: TestTree
settingTests =
  testGroup
    "settings"
    [ testCase "the settings keep their kernel-era keys and variables, and the secret is never shown" do
        fmap (\setting -> (setting.key, setting.environment)) authoritySettings
          @?= [ ("authorization.actions.kikan_en.base_url", "SHIKIGAMI_ACTION_KIKAN_EN_BASE_URL"),
                ("authorization.actions.shomei.base_url", "SHIKIGAMI_ACTION_SHOMEI_BASE_URL"),
                ("authorization.actions.shomei.client_id", "SHIKIGAMI_ACTION_SHOMEI_CLIENT_ID"),
                ("credentials.authorization.actions.shomei.client_secret", "SHIKIGAMI_ACTION_SHOMEI_CLIENT_SECRET"),
                ("authorization.actions.en.issuer_public_keys", "SHIKIGAMI_ACTION_EN_ISSUER_PUBLIC_KEYS"),
                ("authorization.actions.en.schema_hashes", "SHIKIGAMI_ACTION_EN_SCHEMA_HASHES"),
                ("authorization.actions.caller_id", "SHIKIGAMI_ACTION_CALLER_ID")
              ]
        [setting.key | setting <- authoritySettings, setting.shape == SecretTextSetting] @?= ["credentials.authorization.actions.shomei.client_secret"],
      testCase "malformed trust material is refused at start" do
        let check key value = case [setting | setting <- authoritySettings, setting.key == key] of
              [setting] -> setting.validate (String value)
              _ -> Left "no such setting"
        assertBool "issuer keys" (isLeft (check "authorization.actions.en.issuer_public_keys" "1:not-hex"))
        assertBool "schema hashes" (isLeft (check "authorization.actions.en.schema_hashes" " , "))
        assertBool "base url" (isLeft (check "authorization.actions.kikan_en.base_url" "not a url"))
        check "authorization.actions.en.issuer_public_keys" issuerKeys @?= Right ()
        check "authorization.actions.en.schema_hashes" "sha256:test" @?= Right (),
      testCase "complete settings load, and partial ones name every missing key and no value" do
        case loadKikanEnSettings (packSettingsWithSecrets complete [secret]) of
          Left problem -> assertFailure (Text.unpack problem)
          Right loaded -> do
            loaded.kikanBaseUrl @?= "https://kikan.example.test"
            loaded.callerId @?= "shikigami-worker"
        case loadKikanEnSettings (packSettingsWithSecrets (take 2 complete) []) of
          Right _ -> assertFailure "partial settings loaded"
          Left problem -> do
            assertBool (Text.unpack problem) (all (`Text.isInfixOf` problem) ["authorization.actions.shomei.client_id", "credentials.authorization.actions.shomei.client_secret", "authorization.actions.caller_id"])
            assertBool (Text.unpack problem) (not ("authorization.actions.kikan_en.base_url" `Text.isInfixOf` problem))
            assertBool (Text.unpack problem) (not ("kikan.example.test" `Text.isInfixOf` problem))
    ]
  where
    issuerKeys = "1:0000000000000000000000000000000000000000000000000000000000000000"
    secret = ("credentials.authorization.actions.shomei.client_secret", "fixture-machine-secret")
    complete =
      [ ("authorization.actions.kikan_en.base_url", String "https://kikan.example.test"),
        ("authorization.actions.shomei.base_url", String "https://shomei.example.test"),
        ("authorization.actions.shomei.client_id", String "shikigami-worker"),
        ("authorization.actions.en.issuer_public_keys", String issuerKeys),
        ("authorization.actions.en.schema_hashes", String "sha256:test"),
        ("authorization.actions.caller_id", String "shikigami-worker")
      ]
