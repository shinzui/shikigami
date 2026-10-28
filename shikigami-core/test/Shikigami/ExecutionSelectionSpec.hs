module Shikigami.ExecutionSelectionSpec (tests) where

import Baikai.Options (emptyOptions)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingHigh))
import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile), ResolvedProfile (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract (ModelAlias (..), ModelDescriptor (..))
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.Request
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime (currentExecutionAuthority)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionSelection"
    [ testCase "coordinator and worker aliases select distinct exact models" do
        let coordinator = select "coordinator"
            workerA = select "worker-a"
            workerB = select "worker-b"
        map (\s -> s.descriptor.modelId) [coordinator, workerA, workerB] @?= ["stub-coordinator", "stub-worker-a", "stub-worker-b"]
        mapM_ (\selection -> Aeson.eitherDecode (Aeson.encode selection) @?= Right selection) [coordinator, workerA, workerB],
      testCase "user and parent restrictions cannot widen declaration authority" do
        let req alias = Just (ExecutionRequest (Just alias) Nothing Nothing)
            resolve request inherited = resolveExecutionSelection "assignment-test" catalog (Right fallback) (Just permission) request inherited Nothing Nothing fixedTime
        resolve (req "unknown") Nothing @?= Left ExecutionAliasForbidden
        resolve (req "worker-a") (Just ["worker-b"]) @?= Left ExecutionAliasForbidden
        resolve (Just (ExecutionRequest (Just "worker-a") (Just ["worker-b"]) Nothing)) Nothing @?= Left ExecutionRequirementConflict
        resolve (Just (ExecutionRequest (Just "worker-a") Nothing (Just ThinkingHigh))) Nothing @?= Left ExecutionThinkingConflict,
      testCase "an absent declaration keeps the fully pinned process default" do
        let result = mustRight (resolveExecutionSelection "assignment-test" catalog (Right fallback) Nothing Nothing Nothing Nothing Nothing fixedTime)
        result.source @?= ProcessDefault
        result.descriptor @?= modelDescriptor fallback
        resolveExecutionSelection "assignment-test" catalog (Right fallback) Nothing (Just (ExecutionRequest (Just "worker-a") Nothing Nothing)) Nothing Nothing Nothing fixedTime @?= Left ExecutionRequirementConflict,
      testCase "mutable aliases never replace an immutable pinned binding" do
        let original = select "worker-a"
            changed = mustRight (modelCatalog [mustRight (modelBinding (ModelAlias "worker-a") "2" "worker-a" "2" (stubModel & #modelId .~ "different-model") emptyOptions Nothing)])
            retained = mustRight (retainModelBindings changed [binding "worker-a" "stub-worker-a" Nothing])
        assertBool "new alias value refused" (isLeft (selectionBinding changed fallback Nothing original))
        assertBool "retained exact binding usable" (not (isLeft (selectionBinding retained fallback Nothing original)))
        assertBool "changed process default cannot replace old selection" (isLeft (selectionBinding catalog (binding "__process_default__" "different-default" Nothing) Nothing (mustRight (resolveExecutionSelection "assignment-test" catalog (Right fallback) Nothing Nothing Nothing Nothing Nothing fixedTime)))),
      testCase "whole-run permissions and decision permissions stay separate" do
        declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
        let runOnly = declaration & #execution .~ Just permission
            decisionOnly = declaration & #decisionModels .~ ["worker-a"]
        assertBool "run permission grants no decision model" (isLeft (resolveModel catalog runOnly Nothing (ModelAlias "worker-a")))
        assertBool "decision alias does not grant whole-run selection" (isLeft (resolveExecutionSelection "assignment-test" catalog (Right fallback) decisionOnly.execution (Just (ExecutionRequest (Just "worker-a") Nothing Nothing)) Nothing Nothing Nothing fixedTime))
        assertBool "invalid unused whole-run default does not deny a decision alias" (not (isLeft (resolveModel catalog (decisionOnly & #execution .~ Just (ExecutionPolicy "unknown" [])) Nothing (ModelAlias "worker-a")))),
      testCase "historical declarations omit the new default and recover it on decode" do
        declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
        declaration.execution @?= Nothing
        case Aeson.toJSON declaration of
          Aeson.Object fields -> assertBool "no new default key" (not (KeyMap.member "execution" fields))
          _ -> assertFailure "declaration must be an object"
        Aeson.eitherDecode (Aeson.encode declaration) @?= Right declaration,
      testCase "inbound provider flags have no authority" do
        assertBool "unsupported requirement rejected" (isLeft (Aeson.eitherDecode @ExecutionRequest "{\"alias\":\"worker-a\",\"baseUrl\":\"https://untrusted.example\"}")),
      testCase "serialized selection contains no opaque credential" do
        let secret = "PLANTED_EXECUTION_SECRET"
            selected = binding "worker-a" "stub-worker-a" (Just (opaqueCredential secret))
            local = mustRight (modelCatalog [selected])
            result = mustRight (resolveExecutionSelection "assignment-test" local (Right fallback) (Just (ExecutionPolicy "worker-a" ["worker-a"])) Nothing Nothing Nothing Nothing fixedTime)
        assertBool "no credential in JSON" (not ("PLANTED_EXECUTION_SECRET" `isInfixOf` Lazy.unpack (Aeson.encode result))),
      testCase "profile tuple conflicts and unenforceable cost ceilings refuse admission" do
        let resolve profile = resolveExecutionSelection "profile-assignment" catalog (Right fallback) (Just permission) Nothing Nothing (Just profile) Nothing fixedTime
        resolve (profileFor "other-model" Profile.unlimitedProfileLimits) @?= Left ExecutionProfileConflict
        resolve (profileFor "stub-coordinator" (Profile.unlimitedProfileLimits & #maxCostMicroUsd .~ Just 1)) @?= Left ExecutionResourceBoundUnsupported
        let pinned = mustRight (resolve (profileFor "stub-coordinator" Profile.unlimitedProfileLimits))
        assertBool "profile reference pinned" (pinned.profile /= Nothing),
      testCase "fresh profile authority rechecks the exact pinned version without replacement" do
        let pinned = profileFor "stub-coordinator" Profile.unlimitedProfileLimits
            identity = pure (Right ())
            exact profileId version = do
              profileId @?= pinned.ref.profileId
              version @?= Just pinned.ref.version
              pure (Right pinned)
        currentExecutionAuthority identity (Just pinned) exact >>= (@?= Right ())
        currentExecutionAuthority identity (Just pinned) (\profileId version -> pure (Left (UnknownProfile profileId version))) >>= (@?= Left "ExecutionProfileAuthorityRefused")
        currentExecutionAuthority identity (Just pinned) (\_ _ -> pure (Right (profileFor "replacement" Profile.unlimitedProfileLimits))) >>= (@?= Left "ExecutionProfileAuthorityRefused")
    ]

binding :: Text -> Text -> Maybe OpaqueCredential -> ModelBinding
binding alias model credential = mustRight (modelBinding (ModelAlias alias) "1" alias "1" (stubModel & #modelId .~ model) emptyOptions credential)

fallback :: ModelBinding
fallback = mustRight (defaultBinding stubModel emptyOptions)

catalog :: ModelCatalog
catalog = mustRight (modelCatalog [binding alias ("stub-" <> alias) Nothing | alias <- ["coordinator", "worker-a", "worker-b"]])

permission :: ExecutionPolicy
permission = ExecutionPolicy "coordinator" ["coordinator", "worker-a", "worker-b"]

select :: Text -> ExecutionSelection
select alias = mustRight (resolveExecutionSelection "assignment-test" catalog (Right fallback) (Just permission) (Just (ExecutionRequest (Just alias) Nothing Nothing)) Nothing Nothing Nothing fixedTime)

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 10 27) 0

profileFor :: Text -> Profile.ProfileLimits -> ResolvedProfile
profileFor exact limits =
  let content =
        Profile.SanctionedExecutionProfile
          { profileId = Profile.ProfileId "selection-profile",
            version = Profile.ProfileVersion "1",
            issuer = Profile.Issuer "fixture",
            lifecycle = Profile.Active,
            validFrom = fixedTime,
            validUntil = Nothing,
            allowedCalls = Profile.AllowedCall "stub" "stub" "in-process" exact Profile.ThinkingHigh :| [],
            prohibitions = Profile.defaultProhibitions & #defaultedThinkingAllowed .~ True,
            limits,
            minimumEvidenceStrength = Profile.EvidenceRequestedOnly,
            requiredCorrelationFields = [],
            signerRequirements = Profile.noSignerRequirements
          }
   in ResolvedProfile content (Profile.SanctionedExecutionProfileRef content.profileId content.version (profileDigest content))
