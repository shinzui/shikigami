-- | The playbook format and its checked loader (EP-4 of MasterPlan 22).
module Shikigami.PlaybookSpec (tests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shikigami.Playbook
import Shikigami.Playbook.Run (Reflection (..), parseReflection)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "playbooks"
    [ testCase "the example bundle loads and prints its step tree" do
        loaded <- loadBundle "../agents/playbooks/two-repo-review.dhall"
        bundle <- either (assertFailure . show) pure loaded
        take 2 (renderStepTree bundle) @?= ["playbook two-repo-review", "  each-repository  for each repository in run.repositories run review-one"],
      testCase "validation names the step for every kind of error" do
        let step = CodingAgent {id = "fix", prompt = "Fix {{repo}}", workspace = "", deadlineMinutes = 5, skills = []}
            bundle =
              Bundle
                { main = "a",
                  playbooks =
                    [ Playbook {name = "a", steps = [RunPlaybook {id = "to-b", playbook = "b"}, RunPlaybook {id = "missing", playbook = "nowhere"}, step]},
                      Playbook {name = "b", steps = [RunPlaybook {id = "back", playbook = "a"}]}
                    ]
                }
        validateBundle bundle @?= [PlaybookCycle ["a", "b", "a"], UnknownSubPlaybook "a" "missing" "nowhere", UndefinedReference "a" "fix" "repo"]
        validateBundle bundle {main = "z"} @?= [UnknownMainPlaybook "z"],
      testCase "an item variable is visible inside its playbook, and run parameters everywhere" do
        let bundle =
              Bundle
                { main = "m",
                  playbooks =
                    [ Playbook {name = "m", steps = [ForEach {id = "each", items = Literal ["x", "y"], item = "repo", playbook = "one"}]},
                      Playbook {name = "one", steps = [CodingAgent {id = "fix", prompt = "Fix {{repo}} for {{run.focus}}", workspace = "{{repo}}", deadlineMinutes = 5, skills = []}]}
                    ]
                }
        validateBundle bundle @?= [],
      testCase "templates render run parameters and item variables" do
        renderTemplate (Map.fromList [("focus", "docs")]) (Map.fromList [("repo", "mina")]) "In {{repo}}, fix {{ run.focus }}." @?= "In mina, fix docs."
        templateReferences "a {{x}} b {{run.y}}" @?= ["x", "run.y"],
      testCase "{{learnings}} is always defined" do
        validateBundle Bundle {main = "m", playbooks = [Playbook {name = "m", steps = [Reflect {id = "r", prompt = "Given {{learnings}}", workspace = ""}]}]} @?= [],
      testCase "step-sourced items need an earlier step and never name a workspace" do
        let fanOut source = ForEach {id = "each", items = FromStep {step = source, at = "/packages", key = "name"}, item = "package", playbook = "one"}
            tool = Tool {id = "packages", tool = "mori", args = ["registry", "show"], deadlineMinutes = 1}
            inner workspace = Playbook {name = "one", steps = [CodingAgent {id = "fix", prompt = "Look at {{package}} ({{package.path}})", workspace, deadlineMinutes = 5, skills = []}]}
            bundle steps workspace = Bundle {main = "m", playbooks = [Playbook {name = "m", steps}, inner workspace]}
        validateBundle (bundle [tool, fanOut "packages"] "") @?= []
        validateBundle (bundle [fanOut "packages", tool] "") @?= [UnknownSourceStep "m" "each" "packages"]
        validateBundle (bundle [tool, fanOut "packages"] "{{package.path}}") @?= [ObservedWorkspace "one" "fix" "package.path"],
      testCase "a reflection is the last JSON line with learnings, bounded" do
        let message = "I looked.\n{\"learnings\": [\"a\", \"b\", \"c\", \"d\"], \"playbookSuggestion\": \"" <> Text.replicate 5000 "x" <> "\"}\n"
        fmap (.learnings) (parseReflection message) @?= Just ["a", "b", "c"]
        fmap (fmap Text.length . (.suggestion)) (parseReflection message) @?= Just (Just 4096)
        parseReflection "no json here" @?= Nothing
        parseReflection "{\"learnings\": [], \"playbookSuggestion\": null}" @?= Just Reflection {learnings = [], suggestion = Nothing}
    ]
