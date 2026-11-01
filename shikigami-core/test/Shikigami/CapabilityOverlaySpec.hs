module Shikigami.CapabilityOverlaySpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, encode, object, toJSON, (.=))
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay
import Shikigami.Execution.Coordinate (executionCoordinate, executionCoordinateText)
import Shikigami.Trigger.Schedule (parseCron)
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
        eitherDecode (encode left) @?= Right left,
      testCase "rejects every malformed catalog boundary" do
        mkCapabilityCatalog [workspaceReadDescriptor, workspaceReadDescriptor]
          @?= Left DuplicateCapability {capability = workspaceReadId}
        mkCapabilityCatalog [(workspaceReadDescriptor & #tools .~ ([]))]
          @?= Left EmptyCapabilityToolSet {capability = workspaceReadId}
        mkCapabilityCatalog [(workspaceReadDescriptor & #tools .~ ([CapabilityToolDescriptor {name = (executionCoordinate ""), operationClass = Observation}]))]
          @?= Left EmptyCapabilityToolName {capability = workspaceReadId}
        mkCapabilityCatalog
          [ ( workspaceReadDescriptor
                & #tools
                  .~ ( [ CapabilityToolDescriptor {name = (executionCoordinate "same"), operationClass = Observation},
                         CapabilityToolDescriptor {name = (executionCoordinate "same"), operationClass = Observation}
                       ]
                     )
            )
          ]
          @?= Left DuplicateCapabilityToolName {capability = workspaceReadId, name = executionCoordinate "same"},
      testCase "lists catalog entries deterministically and looks them up by id" do
        let catalog = expectRight (mkCapabilityCatalog [workspaceReadDescriptor, repositorySearchDescriptor])
        lookupCapability catalog workspaceReadId @?= Just workspaceReadDescriptor
        listCapabilities catalog @?= [repositorySearchDescriptor, workspaceReadDescriptor],
      testCase "empty resolution needs no identity, behavior compatibility, or policy call" do
        let catalog = expectRight (mkCapabilityCatalog [])
            incompatible = ResolutionSubject {principal = Nothing, mode = Durable, behavior = Deterministic {rule = "none", params = Map.empty}, profile = Nothing}
        resolveCapabilityOverlays catalog (\_ _ -> error "policy must not run") incompatible []
          @?= Right emptyResolvedCapabilitySet,
      testCase "resolves authorized Skill requests to a canonical snapshot" do
        let catalog = expectRight (mkCapabilityCatalog [workspaceReadDescriptor, repositorySearchDescriptor])
            expected = mkResolvedCapabilitySet [repositorySearchDescriptor, workspaceReadDescriptor]
        resolveCapabilityOverlays catalog allow durableSkillSubject [workspaceReadId, repositorySearchId]
          @?= Right expected,
      testCase "refuses duplicate, unknown, missing-identity, denied, and non-Skill requests" do
        let catalog = expectRight (mkCapabilityCatalog [workspaceReadDescriptor])
            unknown = expectRight (mkCapabilityId "unknown.capability")
            noIdentity = (durableSkillSubject & #principal .~ (Nothing))
            nonSkill = (durableSkillSubject & #behavior .~ (Deterministic {rule = "none", params = Map.empty}))
            deny _ CapabilityDescriptor {capability} = Left CapabilityAuthorizationDenied {capability, reason = "policy denied"}
        resolveCapabilityOverlays catalog allow durableSkillSubject [workspaceReadId, workspaceReadId]
          @?= Left DuplicateCapabilityRequest {capability = workspaceReadId}
        resolveCapabilityOverlays catalog allow durableSkillSubject [unknown]
          @?= Left UnknownCapability {capability = unknown}
        resolveCapabilityOverlays catalog allow noIdentity [workspaceReadId]
          @?= Left MissingCapabilityIdentity
        resolveCapabilityOverlays catalog deny durableSkillSubject [workspaceReadId]
          @?= Left CapabilityAuthorizationDenied {capability = workspaceReadId, reason = "policy denied"}
        resolveCapabilityOverlays catalog allow nonSkill [workspaceReadId]
          @?= Left CapabilityBehaviorUnsupported {behaviorKind = "Deterministic"},
      testCase "durable resolution admits observation tools only" do
        let mutation = descriptorWithClass "workspace.write" IdempotentMutation
            emission = descriptorWithClass "workspace.publish" IrreversibleEmission
            mutationId = descriptorId mutation
            emissionId = descriptorId emission
            catalog = expectRight (mkCapabilityCatalog [mutation, emission])
        resolveCapabilityOverlays catalog allow durableSkillSubject [mutationId]
          @?= Left
            DurableCapabilityOperationNotAllowed
              { capability = mutationId,
                name = (executionCoordinate "workspace.write.tool"),
                operationClass = IdempotentMutation
              }
        resolveCapabilityOverlays catalog allow durableSkillSubject [emissionId]
          @?= Left
            DurableCapabilityOperationNotAllowed
              { capability = emissionId,
                name = (executionCoordinate "workspace.publish.tool"),
                operationClass = IrreversibleEmission
              },
      testCase "one-off resolution may retain an authorized mutation" do
        let mutation = descriptorWithClass "workspace.write" IdempotentMutation
            mutationId = descriptorId mutation
            catalog = expectRight (mkCapabilityCatalog [mutation])
        resolveCapabilityOverlays catalog allow ((durableSkillSubject & #mode .~ (OneOff))) [mutationId]
          @?= Right (mkResolvedCapabilitySet [mutation]),
      testCase "request order cannot change resolved equality or JSON bytes" do
        let catalog = expectRight (mkCapabilityCatalog [workspaceReadDescriptor, repositorySearchDescriptor])
            first = resolveCapabilityOverlays catalog allow durableSkillSubject [workspaceReadId, repositorySearchId]
            second = resolveCapabilityOverlays catalog allow durableSkillSubject [repositorySearchId, workspaceReadId]
        first @?= second
        fmap encode first @?= fmap encode second,
      testCase "pins and round-trips resolution refusal JSON" do
        let refusal = CapabilityAuthorizationDenied {capability = workspaceReadId, reason = "policy denied"}
        toJSON refusal
          @?= object
            [ "type" .= ("authorization-denied" :: Text),
              "capability" .= ("workspace.read" :: Text),
              "reason" .= ("policy denied" :: Text)
            ]
        eitherDecode (encode refusal) @?= Right refusal
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
      tools = [CapabilityToolDescriptor {name = (executionCoordinate "workspace.read_file"), operationClass = Observation}]
    }

repositorySearchDescriptor :: CapabilityDescriptor
repositorySearchDescriptor =
  CapabilityDescriptor
    { capability = repositorySearchId,
      revision = revisionOne,
      tools = [CapabilityToolDescriptor {name = (executionCoordinate "repository.search"), operationClass = Observation}]
    }

durableSkillSubject :: ResolutionSubject
durableSkillSubject =
  ResolutionSubject
    { principal = Just (declarationCoordinate "principal_capability_proof"),
      mode = Durable,
      behavior = Skill {path = declarationCoordinate ("agents/skills/triage-note")},
      profile = Nothing
    }

allow :: ResolutionSubject -> CapabilityDescriptor -> Either CapabilityResolutionError ()
allow _ _ = Right ()

descriptorWithClass :: Text -> CapabilityOperationClass -> CapabilityDescriptor
descriptorWithClass capabilityName operationClass =
  CapabilityDescriptor
    { capability = expectRight (mkCapabilityId capabilityName),
      revision = revisionOne,
      tools =
        [ CapabilityToolDescriptor
            { name = executionCoordinate (capabilityName <> ".tool"),
              operationClass
            }
        ]
    }

descriptorId :: CapabilityDescriptor -> CapabilityId
descriptorId CapabilityDescriptor {capability} = capability

expectRight :: (Show error) => Either error value -> value
expectRight = \case
  Left err -> error (show err)
  Right value -> value
