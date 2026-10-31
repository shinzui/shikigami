module Shikigami.RouterDeclarationSpec (tests) where

import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    AmbiguousPolicy (ReturnAmbiguous),
    Behavior (..),
    ExpertiseDecl (..),
    NoMatchPolicy (ReturnNoMatch),
    RouterConfidence (RoutingMedium),
    RouterPolicy (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, parseExpertiseKey)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Prelude
import Shikigami.Router.Declaration
  ( RouterDeclarationError (..),
    renderRouterDeclarationError,
    routerDeclarationErrors,
    selectionLimitNatural,
    validateRouterDeclaration,
    validatedRouterDeclaration,
  )
import Shikigami.Router.SelectionLimit (SelectionLimit, parseSelectionLimit, selectionLimitNatural)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "router declaration"
    [ testCase "accepts a bounded router over its declared delegates" do
        case validateRouterDeclaration baseRouter of
          Left errors -> assertFailure ("expected valid router, got " <> show errors)
          Right validated -> selectionLimitNatural (validatedRouterDeclaration validated ^. #selectionLimit) @?= 2,
      testCase "ordinary specialists may declare expertise without routing" do
        let specialist = baseRouter & #routing .~ Nothing & #delegates .~ map fixtureAgentName []
        routerDeclarationErrors specialist @?= []
        validateRouterDeclaration specialist @?= Left [RouterPolicyMissing],
      testCase "rejects empty keys at admission and duplicate normalized keys in declarations" do
        let invalid =
              baseRouter
                & #expertise
                .~ [ expertiseEntry "OpenTelemetry" "first",
                     expertiseEntry " opentelemetry " "duplicate"
                   ]
            errors = routerDeclarationErrors invalid
        assertBool "empty key is refused by its owner" (isLeft (parseExpertiseKey "  "))
        assertBool "case-folded duplicate is reported" (DuplicateExpertiseKey (fixtureExpertiseKey "opentelemetry") `elem` errors),
      testCase "rejects duplicate delegate names" do
        let invalid = baseRouter & #delegates .~ map fixtureAgentName ["reviewer-a", "reviewer-a"]
        assertBool "duplicate is reported" (DuplicateDelegate (fixtureAgentName "reviewer-a") `elem` routerDeclarationErrors invalid),
      testCase "rejects routing without delegates" do
        let invalid = baseRouter & #delegates .~ map fixtureAgentName []
            errors = routerDeclarationErrors invalid
        assertBool "empty allow-list is reported" (RouterHasNoDelegates `elem` errors),
      testCase "rejects zero and oversized selection bounds" do
        assertBool "zero is rejected" (isLeft (parseSelectionLimit 0))
        assertBool "seventeen is rejected" (isLeft (parseSelectionLimit 17))
        case parseSelectionLimit 0 of
          Left problem -> assertBool "diagnostic carries the authoring bound" ("between 1 and 16 inclusive" `Text.isInfixOf` problem)
          Right _ -> assertFailure "zero selection limit was admitted",
      testCase "rejects a selection bound larger than distinct delegates" do
        let errors = routerDeclarationErrors (withMaximum 3 baseRouter)
        assertBool "fan-out larger than allow-list is reported" (MaxSelectionsExceedsDelegates 3 2 `elem` errors)
    ]

baseRouter :: AgentDecl
baseRouter =
  AgentDecl
    { name = fixtureAgentName "architecture-practice-router",
      description = "Routes architecture practice reviews",
      trigger = Event {eventType = "proof.architecture-practice"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [],
      delegates = map fixtureAgentName ["reviewer-a", "reviewer-b"],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Just basePolicy
    }

basePolicy :: RouterPolicy
basePolicy =
  RouterPolicy
    { maxSelections = fixtureSelectionLimit 2,
      minimumConfidence = RoutingMedium,
      onNoMatch = ReturnNoMatch,
      onAmbiguous = ReturnAmbiguous
    }

withMaximum :: Natural -> AgentDecl -> AgentDecl
withMaximum maximumSelection = #routing . _Just . #maxSelections .~ fixtureSelectionLimit (toInteger maximumSelection)

expertiseEntry :: Text -> Text -> ExpertiseDecl
expertiseEntry key description =
  ExpertiseDecl
    { key = fixtureExpertiseKey key,
      description,
      aliases = [],
      evidenceHints = []
    }

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureSelectionLimit :: Integer -> SelectionLimit
fixtureSelectionLimit = either (error . show) id . parseSelectionLimit . fromInteger

fixtureExpertiseKey :: Text -> ExpertiseKey
fixtureExpertiseKey = either (error . show) id . parseExpertiseKey
