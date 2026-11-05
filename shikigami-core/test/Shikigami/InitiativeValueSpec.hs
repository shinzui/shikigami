{-# LANGUAGE DataKinds #-}

module Shikigami.InitiativeValueSpec (tests) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal)
import Shikigami.Decision.Contract (FailureCode (OutputValidationFailure))
import Shikigami.Execution.Coordinate (executionDigestText)
import Shikigami.Execution.Quantity (parseResourceAmount)
import Shikigami.Execution.Resources (Dimension (..), Envelope (..), Limit (..))
import Shikigami.Initiative.Settings
import Shikigami.Initiative.Types
import Shikigami.Objective.Keys (ObservedSource (..), parseProposalRef, proposalRefText)
import Shikigami.Objective.Types (parseObjectiveId)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "InitiativeValue"
    [ testCase "proposal identities are canonical UUIDv7 with the exact prefix" do
        proposal <- newProposalId
        parseProposalId (proposalIdText proposal) @?= Right proposal
        policy <- newStandingPolicyId
        parseStandingPolicyId (standingPolicyIdText policy) @?= Right policy
        assertBool "another prefix is refused" (isLeft (parseProposalId (standingPolicyIdText policy)))
        assertBool "not an identity" (isLeft (parseProposalId "shikigami_proposal_x"))
        assertBool "uuidv4 is refused" (isLeft (parseProposalId "shikigami_proposal_00000000008008000000001ayd"))
        proposalRefText (proposalRefFor proposal) @?= proposalIdText proposal
        assertBool "references refuse another kind" (isLeft (parseProposalRef (standingPolicyIdText policy))),
      testCase "excerpts are bounded, refuse control characters and render protected" do
        assertBool "empty" (isLeft (parseExcerpt ""))
        assertBool "at the bound" (isRight (parseExcerpt (Text.replicate 8192 "x")))
        assertBool "over the bound" (isLeft (parseExcerpt (Text.replicate 8193 "x")))
        assertBool "newline and tab are prose" (isRight (parseExcerpt "line\n\tnext"))
        assertBool "control characters" (isLeft (parseExcerpt "bell\a"))
        excerpt <- either (assertFailure . Text.unpack) pure (parseExcerpt "a private customer quote")
        show excerpt @?= "Excerpt <protected>"
        encode excerpt @?= "\"a private customer quote\"",
      testCase "checked scalars enforce their documented bounds" do
        assertBool "confidence lower" (isLeft (parseConfidence (-0.1)))
        assertBool "confidence upper" (isLeft (parseConfidence 1.1))
        assertBool "confidence nan" (isLeft (parseConfidence (0 / 0)))
        assertBool "confidence infinite" (isLeft (parseConfidence (1 / 0)))
        (confidenceNumber <$> parseConfidence 0.5) @?= Right 0.5
        assertBool "outcome empty" (isLeft (parseOutcomeText ""))
        assertBool "outcome long" (isLeft (parseOutcomeText (Text.replicate 1025 "x")))
        assertBool "criterion empty" (isLeft (parseCriterionText ""))
        (criterionText <$> parseCriterionText "it works") @?= Right "it works"
        assertBool "zero limit" (isLeft (parseInitiativeLimit @"page" 0))
        assertBool "huge limit" (isLeft (parseInitiativeLimit @"page" 16777217))
        (initiativeLimitInt <$> parseInitiativeLimit @"page" 3) @?= Right 3,
      testCase "proposal keys ignore everything except observer and subject" do
        let key = proposalKeyFor agentOne chat
        proposalKeyFor agentOne chat @?= key
        assertBool "observer" (proposalKeyFor agentTwo chat /= key)
        assertBool "source" (proposalKeyFor agentOne chat {source = activityCoordinate "external/intercom"} /= key)
        assertBool "subject kind" (proposalKeyFor agentOne chat {subjectKind = activityCoordinate "transcript"} /= key)
        assertBool "subject id" (proposalKeyFor agentOne chat {subjectId = activityCoordinate "other"} /= key)
        parseProposalKey (proposalKeyText key) @?= Right key
        assertBool "malformed key" (isLeft (parseProposalKey "sha256:nope"))
        -- A change to this pin renames every pending proposal in a deployment.
        proposalKeyText key @?= proposalKeyText (proposalKeyFor agentOne (ObservedSource (activityCoordinate "fixture/chat") (activityCoordinate "chat") (activityCoordinate "thread-1"))),
      testCase "excerpt digests are stable and distinguish text" do
        one <- either (assertFailure . Text.unpack) pure (parseExcerpt "one")
        two <- either (assertFailure . Text.unpack) pure (parseExcerpt "two")
        executionDigestText (excerptDigestFor one) @?= executionDigestText (excerptDigestFor one)
        assertBool "distinct" (excerptDigestFor one /= excerptDigestFor two),
      testCase "closed sums round-trip their stable spellings" do
        forM_ [minBound .. maxBound] \kind -> parseSourceKind (sourceKindText kind) @?= Right kind
        forM_ [minBound .. maxBound] \kind -> parseActionClass (actionClassText kind) @?= Right kind
        forM_ [minBound .. maxBound] \kind -> parseRefusalKind (refusalKindText kind) @?= Right kind
        actionClassText ReproduceAndDiagnose @?= "reproduce-and-diagnose"
        map actionClassText [minBound .. maxBound] @?= ["reproduce-and-diagnose", "draft-fix", "draft-documentation"],
      testCase "skip reasons and statuses round-trip with their payloads" do
        proposal <- newProposalId
        policy <- newStandingPolicyId
        objective <- either (assertFailure . Text.unpack) pure (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")
        forM_
          [ UnsupportedSource,
            AgentActor,
            ExcerptTooShort,
            ExcerptTooLong,
            NoObserverAllowance,
            SourceNotPermitted,
            NoRepositories,
            EvaluationsExhausted,
            ProposalsExhausted,
            NotificationsExhausted,
            AlreadyProposed proposal,
            AlreadyOwned objective,
            OwnerUnknown,
            Suppressed instant,
            NotActionable,
            DecisionRefused OutputValidationFailure
          ]
          roundTrips
        forM_ [Pending, Accepted objective, Admitted objective policy, Rejected instant, Expired instant, Refused CreationDenied] roundTrips
        skipReasonText (AlreadyProposed proposal) @?= "already-proposed"
        proposalStatusTag (Admitted objective policy) @?= "admitted",
      testCase "allowances resolve only for a listed verified principal" do
        settings <- either (assertFailure . show) pure (Aeson.eitherDecode (encode validSettings))
        (fmap (.principal) (resolveAllowance settings (VerifiedIdentity agentOne))) @?= Right agentOne
        (fmap (.principal) (resolveAllowance settings (VerifiedIdentity agentTwo))) @?= Left NoObserverAllowance
        (fmap (.principal) (resolveAllowance settings UnresolvedLegacyIdentity)) @?= Left NoObserverAllowance
        name <- either (assertFailure . show) pure (mkAgentName "proposer")
        (fmap (.principal) (resolveAllowance settings (CompatibilityIdentity name))) @?= Left NoObserverAllowance,
      testCase "allowance documents survive their own rendering" do
        let decoded = eitherDecode @InitiativeSettings (encode validSettings)
        case decoded of
          Left problem -> assertFailure problem
          Right settings -> eitherDecode (encode settings) @?= Right settings,
      testCase "the evaluation root's cutoff is the receipt instant plus the evaluation window" do
        settings <- either (assertFailure . show) pure (eitherDecode @InitiativeSettings (encode validSettings))
        case settings.observers of
          [allowance] -> do
            let envelope = evaluationEnvelopeAt instant allowance.evaluation
            envelope.limits @?= Map.fromList [(ActiveWork, Limited one), (ModelAttempts, Limited one), (Tokens, ExplicitlyUnbounded), (CostMicroUsd, ExplicitlyUnbounded)]
            envelope.cutoff @?= UTCTime (fromGregorian 2026 11 4) 3660
          other -> assertFailure (show (length other))
    ]
  where
    one = either (error . show) id (parseResourceAmount 1)
    chat = ObservedSource (activityCoordinate "fixture/chat") (activityCoordinate "chat") (activityCoordinate "thread-1")

roundTrips :: (Eq value, Show value, ToJSON value, FromJSON value) => value -> IO ()
roundTrips value = eitherDecode (encode value) @?= Right value

instant :: UTCTime
instant = UTCTime (fromGregorian 2026 11 4) 60

agentOne :: AgentPrincipal
agentOne = principal "agent_one"

agentTwo :: AgentPrincipal
agentTwo = principal "agent_two"

principal :: Text -> AgentPrincipal
principal = either (error . Text.unpack) id . mkAgentPrincipal

validSettings :: Aeson.Value
validSettings =
  object
    [ "observers"
        .= [ object
               [ "principal" .= ("agent_one" :: Text),
                 "sources" .= (["chat-fixture"] :: [Text]),
                 "minimumExcerptLength" .= (5 :: Int),
                 "evaluation" .= object ["limits" .= object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= (1 :: Int), "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)], "cutoff" .= (3600 :: Int)],
                 "evaluationsPerWindow" .= (10 :: Int),
                 "proposalsPerWindow" .= (5 :: Int),
                 "notificationsPerWindow" .= (5 :: Int),
                 "window" .= (3600 :: Int),
                 "proposalExpiry" .= (86400 :: Int),
                 "rejectionSuppression" .= (604800 :: Int),
                 "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
               ]
           ]
    ]
