module Shikigami.CapabilityOverlaySpec (tests) where

import Data.Aeson (eitherDecode, encode, object, toJSON, (.=))
import Data.Foldable (traverse_)
import Data.Text (Text)
import Shikigami.Capability.Overlay
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "CapabilityOverlay"
    [ testCase "validates stable capability identifiers" do
        traverse_ assertInvalidId ["", "Workspace.read", "workspace read", "workspace/read", "workspace..read"]
        capabilityIdText workspaceReadId @?= "workspace.read",
      testCase "requires a non-empty immutable revision" do
        assertBool "empty revision is refused" (isLeft (mkCapabilityRevision ""))
        capabilityRevisionText revisionOne @?= "v1",
      testCase "pins the public descriptor JSON shape" do
        toJSON workspaceReadDescriptor
          @?= object
            [ "capability" .= ("workspace.read" :: Text),
              "revision" .= ("v1" :: Text),
              "tools"
                .= [ object
                       [ "name" .= ("workspace.read_file" :: Text),
                         "operationClass" .= ("Observation" :: Text)
                       ]
                   ]
            ]
        eitherDecode (encode workspaceReadDescriptor) @?= Right workspaceReadDescriptor,
      testCase "normalizes resolved snapshot ordering and bytes" do
        let left = mkResolvedCapabilitySet [workspaceReadDescriptor, repositorySearchDescriptor]
            right = mkResolvedCapabilitySet [repositorySearchDescriptor, workspaceReadDescriptor]
        left @?= right
        encode left @?= encode right
        eitherDecode (encode left) @?= Right left
    ]

assertInvalidId :: Text -> IO ()
assertInvalidId value =
  case mkCapabilityId value of
    Left _ -> pure ()
    Right capability -> assertFailure ("unexpected valid capability id: " <> show capability)

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

workspaceReadId :: CapabilityId
workspaceReadId = expectRight (mkCapabilityId "workspace.read")

repositorySearchId :: CapabilityId
repositorySearchId = expectRight (mkCapabilityId "repository.search")

revisionOne :: CapabilityRevision
revisionOne = expectRight (mkCapabilityRevision "v1")

workspaceReadDescriptor :: CapabilityDescriptor
workspaceReadDescriptor =
  CapabilityDescriptor
    { capability = workspaceReadId,
      revision = revisionOne,
      tools = [CapabilityToolDescriptor {name = "workspace.read_file", operationClass = Observation}]
    }

repositorySearchDescriptor :: CapabilityDescriptor
repositorySearchDescriptor =
  CapabilityDescriptor
    { capability = repositorySearchId,
      revision = revisionOne,
      tools = [CapabilityToolDescriptor {name = "repository.search", operationClass = Observation}]
    }

expectRight :: (Show error) => Either error value -> value
expectRight = \case
  Left err -> error (show err)
  Right value -> value
