{-# LANGUAGE AllowAmbiguousTypes #-}

module Shikigami.WorkspaceProcessPolicySpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.Catalog (repositoryPolicyRevision, resolveRepository)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Settings qualified as Settings
import Shikigami.Workspace.Store qualified as Store
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace retained process policies"
    [ testCase "admission freeze retains boolean storage and rejects other JSON kinds" $ do
        Aeson.encode Store.AdmissionOpen @?= "false"
        Aeson.encode Store.AdmissionFrozen @?= "true"
        Aeson.eitherDecode @Store.FreezeState "false" @?= Right Store.AdmissionOpen
        Aeson.eitherDecode @Store.FreezeState "true" @?= Right Store.AdmissionFrozen
        mapM_ (assertDecodeRefused @Store.FreezeState) [Aeson.Null, Aeson.Number 0, Aeson.String "false", Aeson.object []],
      testCase "complete policy and profile retain numeric format bytes and policy identity" $ do
        Aeson.toJSON policy @?= legacyPolicy
        Aeson.encode policy @?= Aeson.encode legacyPolicy
        Aeson.eitherDecode @ProcessPolicy (Aeson.encode legacyPolicy) @?= Right policy
        let profile = ProcessProfile digest digest policy 62000 62000
            legacyProfile = Aeson.object ["bindingDigest" .= digest, "instructionDigest" .= digest, "policy" .= legacyPolicy, "userId" .= (62000 :: Int), "groupId" .= (62000 :: Int)]
        assertBool "complete valid profile" (validProcessProfile profile)
        Aeson.encode profile @?= Aeson.encode legacyProfile
        Aeson.eitherDecode @ProcessProfile (Aeson.encode legacyProfile) @?= Right profile
        processPolicyIdentity policy @?= "policy2-" <> Text.drop 7 (versionedDigest "shikigami.workspace-supervised-policy/1" (Aeson.toJSON ((1 :: Int), policy.image, policy.propertiesDigest, [rule], ["" :: Text.Text], ["src" :: Text.Text])))
        case legacyPolicy of
          Aeson.Object fields ->
            mapM_
              ( \invalid -> do
                  let changed = Aeson.Object (KeyMap.insert "format" invalid fields)
                  assertDecodeRefused @ProcessPolicy changed
                  case legacyProfile of
                    Aeson.Object profileFields -> assertDecodeRefused @ProcessProfile (Aeson.Object (KeyMap.insert "policy" changed profileFields))
                    _ -> assertFailure "profile must be an object"
              )
              [Aeson.Number 0, Aeson.Number 2, Aeson.Number 1.5, Aeson.String "1", Aeson.Bool True, Aeson.Null]
          _ -> assertFailure "policy must be an object",
      testCase "policy identity binds every command, image and file restriction" $ do
        assertBool "fixture policy valid" (validProcessPolicy policy)
        mapM_
          (\changed -> assertBool "changed reviewed policy has another identity" (processPolicyIdentity changed /= processPolicyIdentity policy))
          [policy & #image . #rootIdentity .~ other, policy & #image . #deadlineExecutable .~ "/bin/other", policy & #propertiesDigest .~ other, policy & #rules .~ [rule & #arguments .~ ["other"]], policy & #writePaths .~ ["lib"], policy & #readPaths .~ ["src"]],
      testCase "irrelevant order converges without changing the retained policy" $ do
        let otherRule = rule & #rule .~ "other"
            one = policy & #rules .~ [rule, otherRule] & #writePaths .~ ["src", "lib"]
            two = one & #rules .~ [otherRule, rule] & #writePaths .~ ["lib", "src"]
        processPolicyIdentity one @?= processPolicyIdentity two,
      testCase "only a selected reviewed rule acquires the exact derived Unix profile" $ do
        processPolicyCommand policy digest "validate" @?= Just (ProcessCommand "validate" digest "/bin/validate" ["$HOME", "%n"] "" (Map.singleton "HOME" "/scratch") 30 1024)
        processPolicyCommand policy digest "shell" @?= Nothing
        processPolicyCommand policy "unqualified" "validate" @?= Nothing,
      testCase "invalid, duplicate and over-budget operator policies refuse" $
        mapM_
          (\invalid -> assertBool "invalid policy" (not (validProcessPolicy invalid)))
          [policy & #rules .~ [], policy & #rules .~ [rule, rule], policy & #rules .~ [rule & #executable .~ "/bin/../sh"], policy & #rules .~ [rule & #timeoutSeconds .~ 0], policy & #rules .~ [rule & #environment .~ Map.singleton "LD_PRELOAD" "/workspace/lib.so"], policy & #rules .~ [rule & #arguments .~ [Text.replicate 262144 "x"]], policy & #image . #rootDirectory .~ "/unsafe/%n", policy & #image . #deadlineExecutable .~ "/workspace/guard", policy & #image . #environmentExecutable .~ "/scratch/env", policy & #writePaths .~ ["../outside"]],
      testCase "identity pools are bounded and stored decoders reject caller extensions" $ do
        mapM_ (\range -> assertBool "invalid pool" (not (validIdentityRange range))) [IdentityRange 0 10, IdentityRange 1000 999, IdentityRange 1000 66536]
        assertBool "reserved pool valid" (validIdentityRange (IdentityRange 62000 62999))
        case Aeson.toJSON policy of
          Aeson.Object fields -> case Aeson.fromJSON @ProcessPolicy (Aeson.Object (KeyMap.insert "hostPath" (Aeson.String "/host") fields)) of
            Aeson.Error _ -> pure ()
            _ -> assertFailure "unknown policy fields accepted"
          _ -> assertFailure "policy must be an object",
      testCase "configured process hosts bind complete policies and refuse inconsistent or unbounded configuration" $ do
        let base = Text.replicate 40 "a"
            repository = Settings.WorkspaceRepository "mori://fixture/repo" "/operator/repo" [Settings.WorkspaceRevision base digest] base "reviewed" [""] ["src"]
            process = Settings.WorkspaceProcessSettings "/run/workspace/supervisor.sock" 0 5 60 (IdentityRange 64000 64031) (Map.singleton repository.identity policy)
            settings = Settings.WorkspaceSettings "/private/workspaces" [repository] [Settings.WorkspaceGrant "worker" "agent_fixture" repository.identity Nothing] (Just process)
            invalid changed = case Settings.validateWorkspaceSettings (settings & #process .~ Just changed) of Left _ -> pure (); Right _ -> assertFailure "invalid process configuration admitted"
        case Settings.validateWorkspaceSettings settings >>= (either (const (Left "resolution refused")) Right . (\catalog -> resolveRepository catalog repository.identity Nothing)) of
          Right selected -> repositoryPolicyRevision selected @?= processPolicyIdentity policy
          Left err -> assertFailure (Text.unpack err)
        mapM_ invalid [process & #socketPath .~ "relative", process & #serverUser .~ (-1), process & #requestSeconds .~ 0, process & #waitSeconds .~ 3601, process & #identities .~ IdentityRange 0 10, process & #policies .~ Map.empty, process & #policies .~ Map.singleton "mori://fixture/other" policy, process & #policies .~ Map.singleton repository.identity (policy & #writePaths .~ [""])]
        let changed = settings & #process .~ Just (process & #policies .~ Map.singleton repository.identity (policy & #rules .~ [rule & #arguments .~ ["new"]]))
        assertBool "same human label cannot change retained command policy" (Settings.configuredPolicyIdentity changed repository /= Settings.configuredPolicyIdentity settings repository),
      testCase "file restrictions use exact path segments and independent read and write scopes" $ do
        mapM_ (\path -> assertBool "approved write scope" (processFileAllowed policy "replace" path)) ["src", "src/file", "src/nested/file"]
        mapM_ (\path -> assertBool "outside write scope" (not (processFileAllowed policy "replace" path))) ["src-other/file", "lib/file", "../src/file", "src/../lib"]
        assertBool "read policy independent" (processFileAllowed policy "read" "lib/file")
        assertBool "unknown operation refuses" (not (processFileAllowed policy "chmod" "src/file"))
    ]

assertDecodeRefused :: forall a. (Aeson.FromJSON a) => Aeson.Value -> IO ()
assertDecodeRefused value = case Aeson.eitherDecode @a (Aeson.encode value) of
  Left _ -> pure ()
  Right _ -> assertFailure "unsupported format admitted"

legacyPolicy :: Aeson.Value
legacyPolicy = Aeson.object ["format" .= (1 :: Int), "image" .= policy.image, "propertiesDigest" .= digest, "rules" .= [rule], "readPaths" .= ["" :: Text.Text], "writePaths" .= ["src" :: Text.Text]]

policy :: ProcessPolicy
policy = ProcessPolicy ProcessPolicyV1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") digest [rule] [""] ["src"]

rule :: CommandRule
rule = CommandRule "validate" "/bin/validate" ["$HOME", "%n"] "" (Map.singleton "HOME" "/scratch") 30 1024

digest, other :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"
other = "sha256:" <> Text.replicate 64 "b"
