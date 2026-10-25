module Main (main) where

import Data.Aeson (Value (Object), toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sort)
import Data.Text (Text)
import Shikigami.Agent.ApiSpec qualified as AgentApiSpec
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Api.OpenApiSpec qualified as OpenApiSpec
import Shikigami.Api.Problem
  ( ProblemCode (..),
    ProblemDetails (..),
    problem,
    problemCodeText,
    problemRetryable,
    problemStatus,
    problemTitle,
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami-api"
        [ packageBoundaryTests,
          problemTests,
          AgentApiSpec.tests,
          OpenApiSpec.tests
        ]
    )

-- ── Package boundary ────────────────────────────────────────────────────────

-- | @shikigami-api@ depends on @shikigami-core@, never the other way round.
--
-- This test exists to fail at /compile/ time rather than at run time: if the
-- arrow were ever reversed, @Shikigami.Agent.Decl@ would not be importable here
-- and the suite would not build. The assertion below is only what makes the
-- import load-bearing, so a linter cannot delete it as unused.
packageBoundaryTests :: TestTree
packageBoundaryTests =
  testGroup
    "package boundary"
    [ testCase "api can consume core's domain declarations" do
        let decl =
              AgentDecl
                { name = "boundary-probe",
                  description = "proves shikigami-api may import shikigami-core",
                  trigger = Schedule {cron = "* * * * *"},
                  behavior = Skill {path = "skills/none"},
                  sinks = [],
                  delegates = [],
                  delegationBudget = Nothing,
                  sanctionedProfile = Nothing,
                  capabilityOverlays = [],
                  identity = Nothing,
                  memory = defaultMemoryPolicy,
                  enabled = True,
                  expertise = [],
                  decisionModels = [],
                  routing = Nothing
                }
        let AgentDecl {name = declaredName} = decl
        declaredName @?= ("boundary-probe" :: Text)
    ]

-- ── RFC 9457 problem details ────────────────────────────────────────────────

allCodes :: [ProblemCode]
allCodes = [minBound .. maxBound]

problemTests :: TestTree
problemTests =
  testGroup
    "ProblemDetails"
    [ testCase "the wire body has exactly the six declared keys" do
        case toJSON (problem NotFound "No resource matches the requested path.") of
          Object o ->
            sort (fmap Key.toString (KeyMap.keys o))
              @?= (["code", "detail", "retryable", "status", "title", "type"] :: [String])
          other -> assertBool ("expected a JSON object, got " <> show other) False,
      testCase "type stays about:blank until documentation URIs exist" $
        (.problemType) (problem Internal "boom") @?= "about:blank",
      testCase "title, status and retryable come from the code, not the call site" do
        let a = problem RateLimited "first"
            b = problem RateLimited "second"
        (.title) a @?= (.title) b
        (.status) a @?= (.status) b
        (.retryable) a @?= (.retryable) b
        (.detail) a @?= "first",
      testCase "every code has a distinct machine-readable identifier" do
        let texts = fmap problemCodeText allCodes
        assertEqual "no duplicate codes" (length allCodes) (length (dedupe texts))
        assertBool "codes are non-empty" (all (/= "") texts),
      testCase "every code has a distinct stable title" do
        let titles = fmap problemTitle allCodes
        assertEqual "no duplicate titles" (length allCodes) (length (dedupe titles)),
      testCase "only 5xx and 429 are advertised as retryable" $
        mapM_
          ( \problemCode ->
              assertEqual
                ("retryable agrees with status for " <> show problemCode)
                (problemStatus problemCode >= 500 || problemStatus problemCode == 429)
                (problemRetryable problemCode)
          )
          allCodes,
      testCase "declared status codes are plausible HTTP statuses" $
        mapM_
          ( \problemCode ->
              assertBool
                ("status in range for " <> show problemCode)
                (problemStatus problemCode >= 400 && problemStatus problemCode < 600)
          )
          allCodes
    ]
  where
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
