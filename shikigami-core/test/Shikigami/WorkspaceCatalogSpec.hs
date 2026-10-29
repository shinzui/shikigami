module Shikigami.WorkspaceCatalogSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Text qualified as Text
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Settings
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "workspace catalog"
    [ testCase "resolves only the configured immutable default" $ withCatalog [policy] $ \catalog ->
        case resolveRepository catalog "mori://fixture/repo" Nothing of
          Left err -> assertFailure (show err)
          Right resolved -> do
            repositoryIdentity resolved @?= "mori://fixture/repo"
            repositorySource resolved @?= "/operator/repo"
            repositoryBase resolved @?= base
            repositoryPolicyRevision resolved @?= "policy-1",
      testCase "caller cannot select host paths or aliases" $ withCatalog [policy] $ \catalog ->
        mapM_ (\name -> refused UnknownRepository (resolveRepository catalog name Nothing)) ["/operator/repo", "repo", "mori://fixture/other", "mori://fixture/repo/", "mori://fixture/repo/../other"],
      testCase "branches, abbreviations and unapproved commits are refused" $ withCatalog [policy] $ \catalog ->
        mapM_ (\revision -> refused RevisionNotAdmitted (resolveRepository catalog policy.identity (Just revision))) ["HEAD", "main", Text.take 7 base, Text.replicate 40 "b"],
      testCase "duplicate identities cannot silently choose a source" $
        refused DuplicateRepositoryIdentity (mkWorkspaceCatalog [policy, policy {source = "/operator/other"}]),
      testCase "catalog rejects invalid identity and path configuration" $ do
        mapM_ (\identity -> refused InvalidRepositoryIdentity (mkWorkspaceCatalog [policy {identity}])) ["/tmp/repo", "mori://fixture/..", "mori://fixture/repo/extra", "mori://fixture/repo?x"]
        mapM_ (\source -> refused InvalidRepositorySource (mkWorkspaceCatalog [policy {source}])) ["relative", "/operator/../repo", "/operator/\0repo"],
      testCase "catalog requires an approved immutable default" $ do
        refused InvalidRepositoryRevisions (mkWorkspaceCatalog [policy {revisions = ["main"], defaultRevision = "main"}])
        refused InvalidRepositoryRevisions (mkWorkspaceCatalog [policy {defaultRevision = Text.replicate 40 "b"}])
        refused InvalidRepositoryPolicyRevision (mkWorkspaceCatalog [policy {policyRevision = ""}]),
      testCase "SHA256 repositories can admit exact commits" $ withCatalog [policy {revisions = [sha256], defaultRevision = sha256}] $ \catalog ->
        case resolveRepository catalog policy.identity (Just sha256) of
          Left err -> assertFailure (show err)
          Right resolved -> repositoryBase resolved @?= sha256,
      testCase "operator settings reject mutable bases, ambiguous grants and unreviewed instructions" $ do
        let revision = WorkspaceRevision base ("sha256:" <> Text.replicate 64 "c")
            repository = WorkspaceRepository "mori://fixture/repo" "/operator/repo" [revision] base "policy-1" [""] ["src"]
            grant = WorkspaceGrant "worker" "agent_fixture" "mori://fixture/repo" Nothing
            settings = WorkspaceSettings "/private/workspaces" [repository] [grant]
        assertBool "reviewed immutable configuration admitted" (not (isLeft (validateWorkspaceSettings settings)))
        mapM_
          (\invalid -> assertBool "invalid operator input refused" (isLeft (validateWorkspaceSettings invalid)))
          [ WorkspaceSettings "/" [repository] [grant],
            WorkspaceSettings "relative" [repository] [grant],
            WorkspaceSettings "/private/workspaces" [repository, repository] [grant],
            WorkspaceSettings "/private/workspaces" [repository] [grant, grant],
            WorkspaceSettings "/private/workspaces" [repository {revisions = [WorkspaceRevision "main" revision.instructionDigest], defaultRevision = "main"}] [grant],
            WorkspaceSettings "/private/workspaces" [repository {revisions = [WorkspaceRevision base "unreviewed"]}] [grant],
            WorkspaceSettings "/private/workspaces" [repository {writePaths = ["../escape"]}] [grant],
            WorkspaceSettings "/private/workspaces" [repository] [grant {repository = "mori://fixture/other"}]
          ]
        pathAdmitted ["src"] "src/file.hs" @?= True
        pathAdmitted ["src"] "src-other/file.hs" @?= False
        pathAdmitted [] "src/file.hs" @?= False
        assertBool "retained policy identity binds path restrictions" (workspacePolicyIdentity repository /= workspacePolicyIdentity (repository {writePaths = [""]})),
      testCase "unknown nested operator settings are never silently ignored" $ do
        let value = Aeson.object ["storageRoot" Aeson..= ("/private/workspaces" :: Text.Text), "repositories" Aeson..= ([] :: [Aeson.Value]), "grants" Aeson..= ([] :: [Aeson.Value]), "allowEverything" Aeson..= True]
        assertBool "unknown field refuses" (case Aeson.fromJSON @WorkspaceSettings value of Aeson.Error _ -> True; _ -> False)
    ]
  where
    base = Text.replicate 40 "a"
    sha256 = Text.replicate 64 "b"
    policy = RepositoryPolicy "mori://fixture/repo" "/operator/repo" [base] base "policy-1"
    withCatalog policies action = either (assertFailure . show) action (mkWorkspaceCatalog policies)
    refused expected = either (@?= expected) (const (assertFailure "unexpected admission"))
