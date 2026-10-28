module Shikigami.RouterDeclarationSpec (tests) where

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
import Shikigami.Prelude
import Shikigami.Router.Declaration
  ( RouterDeclarationError (..),
    renderRouterDeclarationError,
    routerDeclarationErrors,
    selectionLimitNatural,
    validateRouterDeclaration,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "router declaration"
    [ testCase "accepts a bounded router over its declared delegates" do
        case validateRouterDeclaration baseRouter of
          Left errors -> assertFailure ("expected valid router, got " <> show errors)
          Right validated -> selectionLimitNatural (validated ^. #selectionLimit) @?= 2,
      testCase "ordinary specialists may declare expertise without routing" do
        let specialist = baseRouter & #routing .~ Nothing & #delegates .~ []
        routerDeclarationErrors specialist @?= []
        validateRouterDeclaration specialist @?= Left [RouterPolicyMissing],
      testCase "rejects empty and duplicate normalized expertise keys" do
        let invalid =
              baseRouter
                & #expertise
                .~ [ expertiseEntry "  " "empty",
                     expertiseEntry "OpenTelemetry" "first",
                     expertiseEntry " opentelemetry " "duplicate"
                   ]
            errors = routerDeclarationErrors invalid
        assertBool "empty key is reported" (EmptyExpertiseKey 1 `elem` errors)
        assertBool "case-folded duplicate is reported" (DuplicateExpertiseKey "opentelemetry" `elem` errors),
      testCase "rejects duplicate delegate names" do
        let invalid = baseRouter & #delegates .~ ["reviewer-a", "reviewer-a"]
        assertBool "duplicate is reported" (DuplicateDelegate "reviewer-a" `elem` routerDeclarationErrors invalid),
      testCase "rejects routing without delegates" do
        let invalid = baseRouter & #delegates .~ []
            errors = routerDeclarationErrors invalid
        assertBool "empty allow-list is reported" (RouterHasNoDelegates `elem` errors),
      testCase "rejects zero and oversized selection bounds" do
        let zeroErrors = routerDeclarationErrors (withMaximum 0 baseRouter)
            oversizedErrors = routerDeclarationErrors (withMaximum 17 baseRouter)
        assertBool "zero is rejected" (InvalidMaxSelections 0 `elem` zeroErrors)
        assertBool "seventeen is rejected" (InvalidMaxSelections 17 `elem` oversizedErrors)
        assertBool
          "diagnostic carries the authoring bound"
          ("between 1 and 16 inclusive" `Text.isInfixOf` renderRouterDeclarationError (InvalidMaxSelections 0)),
      testCase "rejects a selection bound larger than distinct delegates" do
        let errors = routerDeclarationErrors (withMaximum 3 baseRouter)
        assertBool "fan-out larger than allow-list is reported" (MaxSelectionsExceedsDelegates 3 2 `elem` errors)
    ]

baseRouter :: AgentDecl
baseRouter =
  AgentDecl
    { name = "architecture-practice-router",
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
      delegates = ["reviewer-a", "reviewer-b"],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      decisionModels = [],
      routing = Just basePolicy
    }

basePolicy :: RouterPolicy
basePolicy =
  RouterPolicy
    { maxSelections = 2,
      minimumConfidence = RoutingMedium,
      onNoMatch = ReturnNoMatch,
      onAmbiguous = ReturnAmbiguous
    }

withMaximum :: Natural -> AgentDecl -> AgentDecl
withMaximum maximumSelection = #routing . _Just . #maxSelections .~ maximumSelection

expertiseEntry :: Text -> Text -> ExpertiseDecl
expertiseEntry key description =
  ExpertiseDecl
    { key,
      description,
      aliases = [],
      evidenceHints = []
    }
