{-# LANGUAGE AllowAmbiguousTypes #-}

module Shikigami.WorkspaceProcessPolicySpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude (Lens', lens, (&), (.~))
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.Workspace.Catalog (repositoryPolicyRevision, resolveRepository)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Settings qualified as Settings
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Value
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
        let profile = ((either (error . show) id . mkProcessProfile) (ProcessProfileInput (workspaceCoordinate (digest)) (workspaceCoordinate (digest)) policy ((either (error . show) id . parseWorkspaceIdentity) (62000)) ((either (error . show) id . parseWorkspaceIdentity) (62000))))
            legacyProfile = Aeson.object ["bindingDigest" .= digest, "instructionDigest" .= digest, "policy" .= legacyPolicy, "userId" .= (62000 :: Int), "groupId" .= (62000 :: Int)]
        assertBool "complete valid profile" (validProcessProfile profile)
        Aeson.encode profile @?= Aeson.encode legacyProfile
        Aeson.eitherDecode @ProcessProfile (Aeson.encode legacyProfile) @?= Right profile
        workspaceCoordinateText (processPolicyIdentity policy) @?= "policy2-" <> (Text.drop 7 (versionedDigest "shikigami.workspace-supervised-policy/1" (Aeson.toJSON ((1 :: Int), policy.image, policy.propertiesDigest, [rule], ["" :: Text.Text], ["src" :: Text.Text]))))
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
          [policy & processPolicyFields . #image . processImageFields . #rootIdentity .~ workspaceCoordinate other, policy & processPolicyFields . #image . processImageFields . #deadlineExecutable .~ (workspaceLocator ("/bin/other")), policy & processPolicyFields . #propertiesDigest .~ workspaceCoordinate other, policy & processPolicyFields . #rules .~ [rule & commandRuleFields . #arguments .~ [(workspaceCoordinate ("other"))]], policy & processPolicyFields . #writePaths .~ [(workspaceCoordinate ("lib"))], policy & processPolicyFields . #readPaths .~ [(workspaceCoordinate ("src"))]],
      testCase "irrelevant order converges without changing the retained policy" $ do
        let otherRule = rule & commandRuleFields . #rule .~ (workspaceCoordinate ("other"))
            one = policy & processPolicyFields . #rules .~ [rule, otherRule] & processPolicyFields . #writePaths .~ [(workspaceCoordinate ("src")), (workspaceCoordinate ("lib"))]
            two = one & processPolicyFields . #rules .~ [otherRule, rule] & processPolicyFields . #writePaths .~ [(workspaceCoordinate ("lib")), (workspaceCoordinate ("src"))]
        processPolicyIdentity one @?= processPolicyIdentity two,
      testCase "only a selected reviewed rule acquires the exact derived Unix profile" $ do
        processPolicyCommand policy (workspaceCoordinate (digest)) (workspaceCoordinate ("validate")) @?= Just (ProcessCommand (workspaceCoordinate ("validate")) (workspaceCoordinate (digest)) (workspaceCoordinate ("/bin/validate")) [(workspaceCoordinate ("$HOME")), (workspaceCoordinate ("%n"))] (workspaceCoordinate ("")) (Map.singleton (workspaceCoordinate ("HOME")) (workspaceCoordinate ("/scratch"))) ((either (error . show) id . parseProcessSeconds) (30)) ((either (error . show) id . parseProcessOutputBytes) (1024)))
        processPolicyCommand policy (workspaceCoordinate (digest)) (workspaceCoordinate ("shell")) @?= Nothing
        processPolicyCommand policy (workspaceCoordinate ("unqualified")) (workspaceCoordinate ("validate")) @?= Nothing,
      testCase "invalid, duplicate and over-budget operator policies refuse" $ do
        mapM_
          (assertDecodeRefused @ProcessPolicy . ($ Aeson.toJSON policy))
          [ replaceField "rules" (Aeson.toJSON ([] :: [CommandRule])),
            replaceField "rules" (Aeson.toJSON [rule, rule]),
            alterField "rules" (const (Aeson.toJSON [alterField "executable" (const (Aeson.String "/bin/../sh")) (Aeson.toJSON rule)])),
            replaceField "rules" (Aeson.toJSON [replaceField "environment" (Aeson.object ["LD_PRELOAD" .= ("/workspace/lib.so" :: Text.Text)]) (Aeson.toJSON rule)]),
            replaceField "rules" (Aeson.toJSON [replaceField "arguments" (Aeson.toJSON [Text.replicate 262144 "x"]) (Aeson.toJSON rule)]),
            alterField "image" (replaceField "rootDirectory" (Aeson.String "/unsafe/%n")),
            alterField "image" (replaceField "deadlineExecutable" (Aeson.String "/workspace/guard")),
            alterField "image" (replaceField "environmentExecutable" (Aeson.String "/scratch/env")),
            replaceField "writePaths" (Aeson.toJSON ["../outside" :: Text.Text])
          ]
        assertBool "factory refuses empty rules" (case mkProcessPolicy (processPolicyInput policy & #rules .~ []) of Left _ -> True; _ -> False),
      testCase "identity pools are bounded and stored decoders reject caller extensions" $ do
        mapM_ (assertDecodeRefused @WorkspaceIdentity . Aeson.toJSON) [0, 999, 2147483648 :: Integer]
        mapM_ (assertDecodeRefused @ProcessSeconds . Aeson.toJSON) [0, 3601 :: Integer]
        assertDecodeRefused @RpcPeerUserId (Aeson.Number (-1))
        assertDecodeRefused @RpcRequestSeconds (Aeson.Number 0)
        assertDecodeRefused @RpcWaitSeconds (Aeson.Number 3601)
        let uid = either (error . show) id . parseWorkspaceIdentity
        mapM_
          (\range -> assertBool "invalid pool" (case mkIdentityRange range of Left _ -> True; _ -> False))
          [IdentityRangeInput (uid 1001) (uid 1000), IdentityRangeInput (uid 1000) (uid 66536)]
        assertBool "reserved pool valid" (validIdentityRange (((either (error . show) id . mkIdentityRange) (IdentityRangeInput ((either (error . show) id . parseWorkspaceIdentity) (62000)) ((either (error . show) id . parseWorkspaceIdentity) 62999)))))
        case Aeson.toJSON policy of
          Aeson.Object fields -> case Aeson.fromJSON @ProcessPolicy (Aeson.Object (KeyMap.insert "hostPath" (Aeson.String "/host") fields)) of
            Aeson.Error _ -> pure ()
            _ -> assertFailure "unknown policy fields accepted"
          _ -> assertFailure "policy must be an object",
      testCase "configured process hosts bind complete policies and refuse inconsistent or unbounded configuration" $ do
        let base = Text.replicate 40 "a"
            repository = Settings.WorkspaceRepository (repositoryId ("mori://fixture/repo")) (workspaceLocator ("/operator/repo")) [Settings.WorkspaceRevision (workspaceCoordinate (base)) (workspaceCoordinate (digest))] (workspaceCoordinate (base)) (workspaceCoordinate ("reviewed")) [(workspaceCoordinate (""))] [(workspaceCoordinate ("src"))]
            process = Settings.WorkspaceProcessSettings (workspaceLocator ("/run/workspace/supervisor.sock")) ((either (error . show) id . parseRpcPeerUserId) (0)) ((either (error . show) id . parseRpcRequestSeconds) (5)) ((either (error . show) id . parseRpcWaitSeconds) (60)) (((either (error . show) id . mkIdentityRange) (IdentityRangeInput ((either (error . show) id . parseWorkspaceIdentity) (64000)) ((either (error . show) id . parseWorkspaceIdentity) (64031))))) (Map.singleton repository.identity policy)
            settings = Settings.WorkspaceSettings (workspaceLocator ("/private/workspaces")) [repository] [Settings.WorkspaceGrant ((either (error . show) id . mkAgentName) ("worker")) (declarationCoordinate ("agent_fixture")) repository.identity Nothing] (Just process)
            invalid changed = case Settings.validateWorkspaceSettings (settings & #process .~ Just changed) of Left _ -> pure (); Right _ -> assertFailure "invalid process configuration admitted"
        case Settings.validateWorkspaceSettings settings >>= (either (const (Left "resolution refused")) Right . (\catalog -> resolveRepository catalog repository.identity Nothing)) of
          Right selected -> repositoryPolicyRevision selected @?= processPolicyIdentity policy
          Left err -> assertFailure (Text.unpack err)
        mapM_ invalid [process & #socketPath .~ (workspaceLocator ("relative")), process & #policies .~ Map.empty, process & #policies .~ Map.singleton (repositoryId ("mori://fixture/other")) policy, process & #policies .~ Map.singleton repository.identity (policy & processPolicyFields . #writePaths .~ [(workspaceCoordinate "")])]
        let changed = settings & #process .~ Just (process & #policies .~ Map.singleton repository.identity (policy & processPolicyFields . #rules .~ [rule & commandRuleFields . #arguments .~ [(workspaceCoordinate ("new"))]]))
        assertBool "same human label cannot change retained command policy" (Settings.configuredPolicyIdentity changed repository /= Settings.configuredPolicyIdentity settings repository),
      testCase "file restrictions use exact path segments and independent read and write scopes" $ do
        mapM_ (\path -> assertBool "approved write scope" (processFileAllowed policy "replace" path)) [(workspaceCoordinate ("src")), (workspaceCoordinate ("src/file")), (workspaceCoordinate ("src/nested/file"))]
        mapM_ (\path -> assertBool "outside write scope" (not (processFileAllowed policy "replace" path))) (map workspaceCoordinate ["src-other/file", "lib/file", "../src/file", "src/../lib"])
        assertBool "read policy independent" (processFileAllowed policy "read" (workspaceCoordinate "lib/file"))
        assertBool "unknown operation refuses" (not (processFileAllowed policy "chmod" (workspaceCoordinate "src/file")))
    ]

assertDecodeRefused :: forall a. (Aeson.FromJSON a) => Aeson.Value -> IO ()
assertDecodeRefused value = case Aeson.eitherDecode @a (Aeson.encode value) of
  Left _ -> pure ()
  Right _ -> assertFailure "unsupported format admitted"

legacyPolicy :: Aeson.Value
legacyPolicy = Aeson.object ["format" .= (1 :: Int), "image" .= policy.image, "propertiesDigest" .= digest, "rules" .= [rule], "readPaths" .= ["" :: Text.Text], "writePaths" .= ["src" :: Text.Text]]

policy :: ProcessPolicy
policy = ((either (error . show) id . mkProcessPolicy) (ProcessPolicyInput ProcessPolicyV1 (((either (error . show) id . mkProcessImage) (ProcessImageInput (workspaceLocator ("/qualified/root")) (workspaceCoordinate (digest)) (workspaceLocator ("/bin/env")) (workspaceLocator ("/bin/deadline")) (workspaceLocator ("/qualified/collector"))))) (workspaceCoordinate (digest)) [rule] [(workspaceCoordinate "")] [(workspaceCoordinate "src")]))

rule :: CommandRule
rule = ((either (error . show) id . mkCommandRule) (CommandRuleInput (workspaceCoordinate "validate") (workspaceCoordinate ("/bin/validate")) [(workspaceCoordinate "$HOME"), (workspaceCoordinate "%n")] (workspaceCoordinate "") (Map.singleton (workspaceCoordinate ("HOME")) (workspaceCoordinate ("/scratch"))) ((either (error . show) id . parseProcessSeconds) (30)) ((either (error . show) id . parseProcessOutputBytes) (1024))))

digest, other :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"
other = "sha256:" <> Text.replicate 64 "b"

processPolicyFields :: Lens' ProcessPolicy ProcessPolicyInput
processPolicyFields = lens processPolicyInput (\_ input -> either (error . show) id (mkProcessPolicy input))

processImageFields :: Lens' ProcessImage ProcessImageInput
processImageFields = lens processImageInput (\_ input -> either (error . show) id (mkProcessImage input))

commandRuleFields :: Lens' CommandRule CommandRuleInput
commandRuleFields = lens commandRuleInput (\_ input -> either (error . show) id (mkCommandRule input))

alterField :: Aeson.Key -> (Aeson.Value -> Aeson.Value) -> Aeson.Value -> Aeson.Value
alterField key change (Aeson.Object fields) = Aeson.Object (case KeyMap.lookup key fields of Just value -> KeyMap.insert key (change value) fields; Nothing -> error "missing policy field")
alterField _ _ _ = error "expected policy object"

replaceField :: Aeson.Key -> Aeson.Value -> Aeson.Value -> Aeson.Value
replaceField key value = alterField key (const value)
