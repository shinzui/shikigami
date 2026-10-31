module Shikigami.RouterDecisionSpec (tests) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Shikigami.Agent.Decl
  ( AmbiguousPolicy (ReturnAmbiguous),
    ExpertiseDecl (..),
    NoMatchPolicy (ReturnNoMatch),
    RouterConfidence (..),
    RouterPolicy (..),
  )
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, parseExpertiseKey)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Directory (DirectorySnapshotVersion (..), DirectorySourceKind (DirectoryDisabledSource))
import Shikigami.Prelude hiding ((.=))
import Shikigami.Router.Catalog
  ( CandidateAvailability (..),
    CandidateCatalog (..),
    CandidateEntry (..),
    CatalogVersion (..),
    ExclusionReason (Paused),
  )
import Shikigami.Router.Decision
  ( RouteDecision (..),
    RouteOutcome (..),
    RouteSelection (..),
    RoutingError (..),
    validateRouteDecision,
  )
import Shikigami.Router.SelectionLimit (SelectionLimit, parseSelectionLimit)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "router decision"
    [ testCase "strictly decodes and round-trips a matched decision" do
        eitherDecode (encode matchedDecision) @?= Right matchedDecision,
      testCase "rejects impossible empty and extra-field wire values" do
        let emptyMatched =
              encode
                ( object
                    [ "version" .= (1 :: Int),
                      "catalogVersion" .= testCatalogVersion,
                      "outcome" .= ("matched" :: String),
                      "selections" .= ([] :: [RouteSelection])
                    ]
                )
            extraField =
              encode
                ( object
                    [ "version" .= (1 :: Int),
                      "catalogVersion" .= testCatalogVersion,
                      "outcome" .= ("no-match" :: String),
                      "rationale" .= ("none" :: String),
                      "selections" .= ([] :: [RouteSelection])
                    ]
                )
        assertBool "matched must select at least one candidate" (isLeft (eitherDecode @RouteDecision emptyMatched))
        assertBool "outcome-specific extra fields are refused" (isLeft (eitherDecode @RouteDecision extraField)),
      testCase "accepts a declared available selection at policy confidence" do
        case validateRouteDecision policy catalog matchedDecision of
          Left errors -> assertFailure ("expected valid route, got " <> show errors)
          Right _ -> pure (),
      testCase "accumulates stale, duplicate, unavailable, expertise, confidence, and fan-out refusals" do
        let badSelection =
              RouteSelection
                { agent = fixtureAgentName "paused-reviewer",
                  expertise = map fixtureExpertiseKey ["invented"],
                  confidence = RoutingLow,
                  rationale = "bad"
                }
            decision =
              RouteDecision
                { version = 2,
                  catalogVersion = CatalogVersion "stale",
                  outcome = Matched (badSelection :| [badSelection])
                }
        case validateRouteDecision (policy & #maxSelections .~ (fixtureSelectionLimit 1)) catalog decision of
          Right _ -> assertFailure "expected invalid decision"
          Left errors -> do
            let found = NonEmpty.toList errors
            assertBool "version is checked" (UnsupportedDecisionVersion 2 `elem` found)
            assertBool "catalog is checked" (StaleCatalogVersion testCatalogVersion (CatalogVersion "stale") `elem` found)
            assertBool "duplicates are checked" (DuplicateSelection (fixtureAgentName "paused-reviewer") `elem` found)
            assertBool "lifecycle is checked" (UnavailableSelection (fixtureAgentName "paused-reviewer") Paused `elem` found)
            assertBool "fan-out is checked" (TooManySelections 2 1 `elem` found),
      testCase "validates advisory ambiguous alternatives but never turns them into matched" do
        let alternative = (selection & #agent .~ (fixtureAgentName "missing-reviewer"))
            decision = RouteDecision 1 testCatalogVersion (Ambiguous (alternative :| []) "unclear")
        case validateRouteDecision policy catalog decision of
          Right _ -> assertFailure "expected undeclared alternative refusal"
          Left errors -> assertBool "alternative is checked" (UndeclaredSelection (fixtureAgentName "missing-reviewer") `elem` NonEmpty.toList errors),
      testCase "no-match is a valid semantic outcome with no selections" do
        let decision = RouteDecision 1 testCatalogVersion (NoMatch "nothing relevant")
        case validateRouteDecision policy catalog decision of
          Left errors -> assertFailure ("expected semantic no-match, got " <> show errors)
          Right _ -> pure ()
    ]

matchedDecision :: RouteDecision
matchedDecision = RouteDecision 1 testCatalogVersion (Matched (selection :| []))

selection :: RouteSelection
selection =
  RouteSelection
    { agent = fixtureAgentName "reviewer",
      expertise = map fixtureExpertiseKey ["opentelemetry"],
      confidence = RoutingMedium,
      rationale = "The payload changes trace propagation."
    }

testCatalogVersion :: CatalogVersion
testCatalogVersion = CatalogVersion "catalog-v1"

catalog :: CandidateCatalog
catalog =
  CandidateCatalog
    { router = fixtureAgentName "router",
      version = testCatalogVersion,
      lifecycleSource = DirectoryDisabledSource,
      lifecycleSourceVersion = DirectorySnapshotVersion "directory-v1",
      candidates =
        [ CandidateEntry
            { name = fixtureAgentName "reviewer",
              description = Just "Reviews telemetry",
              expertise = [expertiseEntry],
              availability = Available
            },
          CandidateEntry
            { name = fixtureAgentName "paused-reviewer",
              description = Just "Paused reviewer",
              expertise = [expertiseEntry],
              availability = Excluded Paused
            }
        ],
      unassociatedLoadFailures = 0
    }

expertiseEntry :: ExpertiseDecl
expertiseEntry =
  ExpertiseDecl
    { key = fixtureExpertiseKey "opentelemetry",
      description = "OpenTelemetry",
      aliases = ["otel"],
      evidenceHints = ["traceparent"]
    }

policy :: RouterPolicy
policy =
  RouterPolicy
    { maxSelections = fixtureSelectionLimit 2,
      minimumConfidence = RoutingMedium,
      onNoMatch = ReturnNoMatch,
      onAmbiguous = ReturnAmbiguous
    }

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureExpertiseKey :: Text -> ExpertiseKey
fixtureExpertiseKey = either (error . show) id . parseExpertiseKey

fixtureSelectionLimit :: Integer -> SelectionLimit
fixtureSelectionLimit = either (error . show) id . parseSelectionLimit . fromInteger
