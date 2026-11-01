module Shikigami.WorkspaceCatalogSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Repository (RepositoryId (..))
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Value
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "workspace catalog"
    [ testCase "resolves only the configured immutable default" $ withCatalog [policy] $ \catalog ->
        case resolveRepository catalog (RepositoryId ("mori://fixture/repo")) Nothing of
          Left err -> assertFailure (show err)
          Right resolved -> do
            repositoryIdentity resolved @?= (RepositoryId ("mori://fixture/repo"))
            repositorySource resolved @?= (workspaceLocator ("/operator/repo"))
            repositoryBase resolved @?= (workspaceCoordinate (base))
            repositoryPolicyRevision resolved @?= (workspaceCoordinate ("policy-1")),
      testCase "caller cannot select host paths or aliases" $ withCatalog [policy] $ \catalog ->
        mapM_ (\name -> refused UnknownRepository (resolveRepository catalog name Nothing)) (map RepositoryId ["/operator/repo", "repo", "mori://fixture/other", "mori://fixture/repo/", "mori://fixture/repo/../other"]),
      testCase "branches, abbreviations and unapproved commits are refused" $ withCatalog [policy] $ \catalog ->
        mapM_ (\revision -> refused RevisionNotAdmitted (resolveRepository catalog policy.identity (Just revision))) [(workspaceCoordinate ("HEAD")), (workspaceCoordinate ("main")), (workspaceCoordinate (Text.take 7 base)), (workspaceCoordinate (Text.replicate 40 "b"))],
      testCase "duplicate identities cannot silently choose a source" $
        refused DuplicateRepositoryIdentity (mkWorkspaceCatalog [policy, (policy & #source .~ ((workspaceLocator ("/operator/other"))))]),
      testCase "catalog rejects invalid identity and path configuration" $ do
        mapM_ (\identity -> refused InvalidRepositoryIdentity (mkWorkspaceCatalog [policy {identity}])) (map RepositoryId ["/tmp/repo", "mori://fixture/..", "mori://fixture/repo/extra", "mori://fixture/repo?x"])
        mapM_ (\source -> refused InvalidRepositorySource (mkWorkspaceCatalog [policy {source}])) (map workspaceLocator ["relative", "/operator/../repo", "/operator/\0repo"]),
      testCase "catalog requires an approved immutable default" $ do
        refused InvalidRepositoryRevisions (mkWorkspaceCatalog [(policy & #revisions .~ ([(workspaceCoordinate ("main"))]) & #defaultRevision .~ (workspaceCoordinate "main"))])
        refused InvalidRepositoryRevisions (mkWorkspaceCatalog [(policy & #defaultRevision .~ (workspaceCoordinate (Text.replicate 40 "b")))])
        refused InvalidRepositoryPolicyRevision (mkWorkspaceCatalog [(policy & #policyRevision .~ ((workspaceCoordinate (""))))]),
      testCase "SHA256 repositories can admit exact commits" $ withCatalog [(policy & #revisions .~ ([sha256]) & #defaultRevision .~ (sha256))] $ \catalog ->
        case resolveRepository catalog policy.identity (Just sha256) of
          Left err -> assertFailure (show err)
          Right resolved -> repositoryBase resolved @?= sha256,
      testCase "operator settings reject mutable bases, ambiguous grants and unreviewed instructions" $ do
        let revision = WorkspaceRevision (workspaceCoordinate (base)) (workspaceCoordinate ("sha256:" <> Text.replicate 64 "c"))
            repository = WorkspaceRepository (RepositoryId ("mori://fixture/repo")) (workspaceLocator ("/operator/repo")) [revision] (workspaceCoordinate (base)) (workspaceCoordinate ("policy-1")) [(workspaceCoordinate (""))] [(workspaceCoordinate "src")]
            grant = WorkspaceGrant ((either (error . show) id . mkAgentName) ("worker")) (declarationCoordinate ("agent_fixture")) (RepositoryId ("mori://fixture/repo")) Nothing
            settings = WorkspaceSettings (workspaceLocator ("/private/workspaces")) [repository] [grant] Nothing
        assertBool "reviewed immutable configuration admitted" (not (isLeft (validateWorkspaceSettings settings)))
        mapM_
          (\invalid -> assertBool "invalid operator input refused" (isLeft (validateWorkspaceSettings invalid)))
          [ WorkspaceSettings (workspaceLocator ("/")) [repository] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "relative") [repository] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [repository, repository] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [repository] [grant, grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [(repository & #revisions .~ ([WorkspaceRevision (workspaceCoordinate "main") revision.instructionDigest]) & #defaultRevision .~ (workspaceCoordinate "main"))] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [(repository & #revisions .~ ([WorkspaceRevision (workspaceCoordinate (base)) (workspaceCoordinate ("unreviewed"))]))] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [(repository & #writePaths .~ ([(workspaceCoordinate ("../escape"))]))] [grant] Nothing,
            WorkspaceSettings (workspaceLocator "/private/workspaces") [repository] [(grant & #repository .~ ((RepositoryId ("mori://fixture/other"))))] Nothing
          ]
        pathAdmitted [(workspaceCoordinate ("src"))] (workspaceCoordinate ("src/file.hs")) @?= True
        pathAdmitted [workspaceCoordinate "src"] (workspaceCoordinate ("src-other/file.hs")) @?= False
        pathAdmitted [] (workspaceCoordinate "src/file.hs") @?= False
        assertBool "retained policy identity binds path restrictions" (workspacePolicyIdentity repository /= workspacePolicyIdentity ((repository & #writePaths .~ ([(workspaceCoordinate (""))])))),
      testCase "unknown nested operator settings are never silently ignored" $ do
        let value = Aeson.object ["storageRoot" .= ("/private/workspaces" :: Text.Text), "repositories" .= ([] :: [Aeson.Value]), "grants" .= ([] :: [Aeson.Value]), "allowEverything" .= True]
        assertBool "unknown field refuses" (case Aeson.fromJSON @WorkspaceSettings value of Aeson.Error _ -> True; _ -> False)
    ]
  where
    base = Text.replicate 40 "a"
    sha256 = workspaceCoordinate (Text.replicate 64 "b")
    policy = RepositoryPolicy (RepositoryId ("mori://fixture/repo")) (workspaceLocator ("/operator/repo")) [(workspaceCoordinate (base))] (workspaceCoordinate (base)) (workspaceCoordinate ("policy-1"))
    withCatalog policies action = either (assertFailure . show) action (mkWorkspaceCatalog policies)
    refused expected = either (@?= expected) (const (assertFailure "unexpected admission"))
