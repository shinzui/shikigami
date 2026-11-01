module Shikigami.ExecutionSelectionSpec (tests) where

import Baikai.Options (emptyOptions)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingHigh))
import Control.Lens ((&), (.~))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as AssignmentText
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile), ResolvedProfile, ResolvedProfileView (..), resolvedProfileFor, resolvedProfileView)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract (ModelAlias, ModelDescriptor (..), versionedDigest)
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.AssignmentKey (AssignmentKey, assignmentIdFor, assignmentKeyText, conversationAssignmentIdFor, parseAssignmentKey)
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Policy.Limits (PolicyNumber (..))
import Shikigami.Execution.Policy.Types qualified as Harness
import Shikigami.Execution.Request
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime (currentExecutionAuthority)
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Transcript (executionIdFor)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionSelection"
    [ testCase "permission and selection codecs reject empty retained aliases" do
        let positive = select "worker-a"
        Aeson.eitherDecode (Aeson.encode positive) @?= Right positive
        Aeson.eitherDecode "{\"alias\":\"worker-a\"}" @?= Right (ExecutionRequest (Just (fixtureModelAlias "worker-a")) Nothing Nothing)
        Aeson.eitherDecode "{\"defaultAlias\":\"worker-a\",\"permittedAliases\":[\"worker-a\"]}" @?= Right (ExecutionPolicy (fixtureModelAlias "worker-a") [fixtureModelAlias "worker-a"])
        Aeson.eitherDecode "{\"rootId\":null,\"request\":null,\"permittedAliases\":[\"worker-a\"]}" @?= Right (ExecutionContext Nothing Nothing (Just [fixtureModelAlias "worker-a"]))
        mapM_
          (\wire -> assertBool "request key refused" (isLeft (Aeson.eitherDecode @ExecutionRequest wire)))
          ["{\"alias\":\"\"}", "{\"permittedAliases\":[\"\"]}"]
        assertBool "declaration key refused" (isLeft (Aeson.eitherDecode @ExecutionPolicy "{\"defaultAlias\":\"\",\"permittedAliases\":[\"worker-a\"]}"))
        assertBool "inherited key refused" (isLeft (Aeson.eitherDecode @ExecutionContext "{\"rootId\":null,\"request\":null,\"permittedAliases\":[\"\"]}"))
        case Aeson.toJSON positive of
          Aeson.Object fields -> assertBool "retained selection key refused" (case Aeson.fromJSON @ExecutionSelection (Aeson.Object (KeyMap.insert "permittedAliases" (Aeson.toJSON ([""] :: [Text])) fields)) of Aeson.Error _ -> True; _ -> False)
          _ -> assertFailure "selection control was not an object",
      testCase "selection retains its permission list and key bounds" do
        let resolve inherited request = resolveExecutionSelection (fixtureAssignment "alias-bounds") catalog (Right fallback) (Just permission) request inherited Nothing Nothing fixedTime
            oversized = fixtureModelAlias (Text.replicate 257 "x")
            excessive = map (fixtureModelAlias . Text.pack . show) [1 .. 65 :: Int]
        assertBool "positive inherited restriction admitted" (not (isLeft (resolve (Just [fixtureModelAlias "coordinator"]) Nothing)))
        resolve (Just [oversized]) Nothing @?= Left InvalidExecutionPermission
        resolve (Just excessive) Nothing @?= Left InvalidExecutionPermission
        resolve (Just [fixtureModelAlias "worker-a", fixtureModelAlias "worker-a"]) Nothing @?= Left InvalidExecutionPermission
        resolve Nothing (Just (ExecutionRequest Nothing (Just [oversized]) Nothing)) @?= Left InvalidExecutionPermission,
      testCase "assignment keys preserve selection bytes and technical derivation" do
        let selection = select "worker-a"
            raw = "assignment-test" :: Text
            expected = Aeson.object ["assignmentId" .= raw, "descriptor" .= selection.descriptor, "effectiveOptions" .= selection.effectiveOptions, "permittedAliases" .= selection.permittedAliases, "profile" .= selection.profile, "rootId" .= selection.rootId, "source" .= selection.source, "admittedAt" .= selection.admittedAt]
        Aeson.eitherDecode (Aeson.encode selection) @?= Right selection
        Aeson.encode selection @?= Aeson.encode expected
        mapM_
          ( \key -> do
              let assignment = assignmentIdFor key
                  old = "assignment:" <> versionedDigest "shikigami.assignment/1" (Aeson.toJSON key)
                  conversation = assignmentIdFor (versionedDigest "shikigami.conversation-assignment/1" (Aeson.object ["workflow" .= key, "message" .= ("日本" :: Text)]))
              assignmentKeyText assignment @?= old
              Aeson.encode assignment @?= Aeson.encode old
              parseAssignmentKey old @?= Right assignment
              Aeson.toJSON (executionIdFor assignment) @?= Aeson.toJSON ("execution:" <> versionedDigest "shikigami.execution/1" (Aeson.toJSON old))
              conversationAssignmentIdFor key "日本" @?= conversation
          )
          ["", "workflow:one", "日本", Text.replicate 10000 "x"]
        mapM_ (\rawKey -> Aeson.eitherDecode (Aeson.encode rawKey) @?= Right (fixtureAssignment rawKey)) [" ", "日本", Text.replicate 256 "x"]
        mapM_
          ( \bad -> do
              assertBool "invalid scalar refused" (isLeft (parseAssignmentKey bad))
              case expected of
                Aeson.Object fields -> assertBool "invalid selection key refused" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert "assignmentId" (Aeson.toJSON bad) fields)) :: Aeson.Result ExecutionSelection of Aeson.Error _ -> True; _ -> False)
                _ -> assertFailure "selection control was not an object"
          )
          ["", Text.replicate 257 "x"],
      testCase "call-limit codecs retain numbers and factory admission refuses negative protocol ceilings" do
        let wire = Profile.unlimitedProfileLimits & #maxCalls .~ Just (either (error . show) id (PV.mkCeiling 3)) & #maxRetries .~ Just (either (error . show) id (PV.mkCeiling 2)) & #maxConcurrency .~ Just (either (error . show) id (PV.mkCeiling 1)) & #maxTokens .~ Just (either (error . show) id (PV.mkCeiling 10))
            make limits = Calls.callLimitsFor (select "worker-a") (Just (profileFor "stub-worker-a" limits))
            limits = mustRight (make wire)
            expected = Aeson.object ["calls" .= (3 :: Integer), "retries" .= (2 :: Integer), "concurrency" .= (1 :: Integer), "cutoff" .= Aeson.Null, "tokens" .= (10 :: Integer)]
        Aeson.fromJSON (Aeson.toJSON limits) @?= Aeson.Success limits
        Aeson.encode limits @?= Aeson.encode expected
        case Aeson.toJSON wire of
          Aeson.Object fields ->
            mapM_
              (\key -> assertBool "invalid protocol ceiling refused" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert key (Aeson.toJSON (-1 :: Int)) fields)) :: Aeson.Result Profile.ProfileLimits of Aeson.Error _ -> True; _ -> False))
              ["maxCalls", "maxRetries", "maxConcurrency", "maxTokens", "maxDurationSeconds"]
          _ -> assertFailure "profile limits were not an object"
        case Aeson.toJSON limits of
          Aeson.Object fields ->
            mapM_
              ( \(key, number) -> case Aeson.fromJSON (Aeson.Object (KeyMap.insert key (Aeson.toJSON (number :: Integer)) fields)) :: Aeson.Result Calls.CallLimits of
                  Aeson.Error _ -> pure ()
                  Aeson.Success _ -> assertFailure "invalid call limit decoded"
              )
              [(key, number) | key <- ["calls", "retries", "concurrency", "tokens"], number <- [-1, toInteger (maxBound :: Int64) + 1]]
          _ -> assertFailure "call limits did not encode as an object",
      testCase "coordinator and worker aliases select distinct exact models" do
        let coordinator = select "coordinator"
            workerA = select "worker-a"
            workerB = select "worker-b"
        map (\s -> Coordinate.providerCoordinateText s.descriptor.modelId) [coordinator, workerA, workerB] @?= ["stub-coordinator", "stub-worker-a", "stub-worker-b"]
        mapM_ (\selection -> Aeson.eitherDecode (Aeson.encode selection) @?= Right selection) [coordinator, workerA, workerB],
      testCase "user and parent restrictions cannot widen declaration authority" do
        let req alias = Just (ExecutionRequest (Just (fixtureModelAlias alias)) Nothing Nothing)
            resolve request inherited = resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) (Just permission) request inherited Nothing Nothing fixedTime
        resolve (req "unknown") Nothing @?= Left ExecutionAliasForbidden
        resolve (req "worker-a") (Just [fixtureModelAlias "worker-b"]) @?= Left ExecutionAliasForbidden
        resolve (Just (ExecutionRequest (Just (fixtureModelAlias "worker-a")) (Just (map fixtureModelAlias ["worker-b"])) Nothing)) Nothing @?= Left ExecutionRequirementConflict
        resolve (Just (ExecutionRequest (Just (fixtureModelAlias "worker-a")) Nothing (Just ThinkingHigh))) Nothing @?= Left ExecutionThinkingConflict,
      testCase "an absent declaration keeps the fully pinned process default" do
        let result = mustRight (resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) Nothing Nothing Nothing Nothing Nothing fixedTime)
        result.source @?= ProcessDefault
        result.descriptor @?= modelDescriptor fallback
        resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) Nothing (Just (ExecutionRequest (Just (fixtureModelAlias "worker-a")) Nothing Nothing)) Nothing Nothing Nothing fixedTime @?= Left ExecutionRequirementConflict,
      testCase "mutable aliases never replace an immutable pinned binding" do
        let original = select "worker-a"
            changed = mustRight (modelCatalog [mustRight (modelBinding (fixtureModelAlias "worker-a") "2" "worker-a" "2" (stubModel & #modelId .~ "different-model") emptyOptions Nothing)])
            retained = mustRight (retainModelBindings changed [binding "worker-a" "stub-worker-a" Nothing])
        assertBool "new alias value refused" (isLeft (selectionBinding changed fallback Nothing original))
        assertBool "retained exact binding usable" (not (isLeft (selectionBinding retained fallback Nothing original)))
        assertBool "changed process default cannot replace old selection" (isLeft (selectionBinding catalog (binding "__process_default__" "different-default" Nothing) Nothing (mustRight (resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) Nothing Nothing Nothing Nothing Nothing fixedTime)))),
      testCase "whole-run permissions and decision permissions stay separate" do
        declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
        let runOnly = declaration & #execution .~ Just permission
            decisionOnly = declaration & #decisionModels .~ (map fixtureModelAlias ["worker-a"])
        assertBool "run permission grants no decision model" (isLeft (resolveModel catalog runOnly Nothing (fixtureModelAlias "worker-a")))
        assertBool "decision alias does not grant whole-run selection" (isLeft (resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) decisionOnly.execution (Just (ExecutionRequest (Just (fixtureModelAlias "worker-a")) Nothing Nothing)) Nothing Nothing Nothing fixedTime))
        assertBool "invalid unused whole-run default does not deny a decision alias" (not (isLeft (resolveModel catalog (decisionOnly & #execution .~ Just (ExecutionPolicy (fixtureModelAlias "unknown") [])) Nothing (fixtureModelAlias "worker-a")))),
      testCase "Dhall agent harness narrows the shared policy and survives JSON replay" do
        declaration <- mustRight <$> loadAgent "test/fixtures/harness-agent.dhall"
        policy <- pure (mustRight (Harness.narrowHarnessPolicy Harness.defaultHarnessPolicy declaration.harness))
        policy.maxModelTurns @?= (fixturePolicy 2)
        policy.deniedTools @?= (map ExecutionValue.executionCoordinate ["write"])
        policy.output @?= Harness.NonemptyReply
        Aeson.eitherDecode (Aeson.encode declaration) @?= Right declaration,
      testCase "historical declarations omit the new default and recover it on decode" do
        declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
        declaration.execution @?= Nothing
        declaration.harness @?= Nothing
        case Aeson.toJSON declaration of
          Aeson.Object fields -> assertBool "no new default keys" (all (not . (`KeyMap.member` fields)) ["execution", "harness"])
          _ -> assertFailure "declaration must be an object"
        Aeson.eitherDecode (Aeson.encode declaration) @?= Right declaration,
      testCase "inbound provider flags have no authority" do
        assertBool "unsupported requirement rejected" (isLeft (Aeson.eitherDecode @ExecutionRequest "{\"alias\":\"worker-a\",\"baseUrl\":\"https://untrusted.example\"}")),
      testCase "serialized selection contains no opaque credential" do
        let secret = "PLANTED_EXECUTION_SECRET"
            selected = binding "worker-a" "stub-worker-a" (Just (opaqueCredential secret))
            local = mustRight (modelCatalog [selected])
            result = mustRight (resolveExecutionSelection (fixtureAssignment "assignment-test") local (Right fallback) (Just (ExecutionPolicy (fixtureModelAlias "worker-a") (map fixtureModelAlias ["worker-a"]))) Nothing Nothing Nothing Nothing fixedTime)
        assertBool "no credential in JSON" (not ("PLANTED_EXECUTION_SECRET" `isInfixOf` Lazy.unpack (Aeson.encode result))),
      testCase "secret header and metadata options never enter durable selection bytes" do
        mapM_
          ( \options -> do
              let selected = mustRight (defaultBinding stubModel options)
              resolveExecutionSelection (fixtureAssignment "private-options") (mustRight (modelCatalog [])) (Right selected) Nothing Nothing Nothing Nothing Nothing fixedTime @?= Left ExecutionOptionsIncompatible
          )
          [emptyOptions & #headers .~ Map.singleton "Authorization" "PLANTED_HEADER_SECRET", emptyOptions & #metadata .~ Map.singleton "authorizationProof" "PLANTED_PROOF_SECRET"],
      testCase "profile tuple conflicts and unenforceable cost ceilings refuse admission" do
        let resolve profile = resolveExecutionSelection (fixtureAssignment "profile-assignment") catalog (Right fallback) (Just permission) Nothing Nothing (Just profile) Nothing fixedTime
        resolve (profileFor "other-model" Profile.unlimitedProfileLimits) @?= Left ExecutionProfileConflict
        resolve (profileFor "stub-coordinator" (Profile.unlimitedProfileLimits & #maxCostMicroUsd .~ Just (either (error . show) id (PV.mkCeiling 1)))) @?= Left ExecutionResourceBoundUnsupported
        let pinned = mustRight (resolve (profileFor "stub-coordinator" Profile.unlimitedProfileLimits))
        assertBool "profile reference pinned" (pinned.profile /= Nothing),
      testCase "fresh profile authority rechecks the exact pinned version without replacement" do
        let pinned = profileFor "stub-coordinator" Profile.unlimitedProfileLimits
            identity = pure (Right ())
            exact profileId version = do
              profileId @?= (resolvedProfileView pinned).ref.profileId
              version @?= Just (resolvedProfileView pinned).ref.version
              pure (Right pinned)
        currentExecutionAuthority identity (Just pinned) exact >>= (@?= Right ())
        currentExecutionAuthority identity (Just pinned) (\profileId version -> pure (Left (UnknownProfile profileId version))) >>= (@?= Left "ExecutionProfileAuthorityRefused")
        currentExecutionAuthority identity (Just pinned) (\_ _ -> pure (Right (profileFor "replacement" Profile.unlimitedProfileLimits))) >>= (@?= Left "ExecutionProfileAuthorityRefused")
    ]

binding :: Text -> Text -> Maybe OpaqueCredential -> ModelBinding
binding alias model credential = mustRight (modelBinding (fixtureModelAlias alias) "1" alias "1" (stubModel & #modelId .~ model) emptyOptions credential)

fallback :: ModelBinding
fallback = mustRight (defaultBinding stubModel emptyOptions)

catalog :: ModelCatalog
catalog = mustRight (modelCatalog [binding alias ("stub-" <> alias) Nothing | alias <- ["coordinator", "worker-a", "worker-b"]])

permission :: ExecutionPolicy
permission = ExecutionPolicy (fixtureModelAlias "coordinator") (map fixtureModelAlias ["coordinator", "worker-a", "worker-b"])

select :: Text -> ExecutionSelection
select alias = mustRight (resolveExecutionSelection (fixtureAssignment "assignment-test") catalog (Right fallback) (Just permission) (Just (ExecutionRequest (Just (fixtureModelAlias alias)) Nothing Nothing)) Nothing Nothing Nothing fixedTime)

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
            allowedCalls = Profile.AllowedCall (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate exact) Profile.ThinkingHigh :| [],
            prohibitions = Profile.defaultProhibitions & #defaultedThinkingAllowed .~ PV.Permitted,
            limits,
            minimumEvidenceStrength = Profile.EvidenceRequestedOnly,
            requiredCorrelationFields = [],
            signerRequirements = Profile.noSignerRequirements
          }
   in resolvedProfileFor content

fixturePolicy :: (PolicyNumber a) => Integer -> a
fixturePolicy number = either (error . show) id (parsePolicyNumber number)

fixtureAssignment :: AssignmentText.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
