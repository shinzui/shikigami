-- | The playbook format and its checked loader (EP-4 of MasterPlan 22).
module Shikigami.PlaybookSpec (tests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (execState, modify)
import Shikigami.CodingAgent.Types (CodingAgentProvider (ClaudeCode), WorkspaceAccess (EditWorkspace))
import Shikigami.DeclaredTool.Workflow (ToolRun (..), ToolStepOutcome (..))
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement (..))
import Shikigami.Flow.Capability (Memory (..))
import Shikigami.Flow.CodingAgent (unavailableCodingAgent)
import Shikigami.Flow.DeclaredTool (DeclaredTool (..), unavailableDeclaredTool)
import Shikigami.Playbook
import Shikigami.Playbook.Run (PlaybookAgent (..), Reflection (..), parseReflection, runPlaybook, stoppedByEnvironment)
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
      testCase "steps.ID.output names an earlier step and never a workspace" do
        let probe = Tool {id = "probe", tool = "git", args = ["status"], deadlineMinutes = 1}
            fix workspace = CodingAgent {id = "fix", prompt = "Status: {{steps.probe.output}} ({{steps.probe.summary}})", workspace, deadlineMinutes = 5, skills = []}
            bundle steps = Bundle {main = "m", playbooks = [Playbook {name = "m", steps}]}
        validateBundle (bundle [probe, fix ""]) @?= []
        validateBundle (bundle [fix "", probe]) @?= [UndefinedReference "m" "fix" "steps.probe.output", UndefinedReference "m" "fix" "steps.probe.summary"]
        validateBundle (bundle [probe, fix "{{steps.probe.output}}"]) @?= [ObservedWorkspace "m" "fix" "steps.probe.output"],
      testCase "a reflection is the last JSON line with learnings, bounded" do
        let message = "I looked.\n{\"learnings\": [\"a\", \"b\", \"c\", \"d\"], \"playbookSuggestion\": \"" <> Text.replicate 5000 "x" <> "\"}\n"
        fmap (.learnings) (parseReflection message) @?= Just ["a", "b", "c"]
        fmap (fmap Text.length . (.suggestion)) (parseReflection message) @?= Just (Just 4096)
        parseReflection "no json here" @?= Nothing
        parseReflection "{\"learnings\": [], \"playbookSuggestion\": null}" @?= Just Reflection {learnings = [], suggestion = Nothing},
      testCase "a stop names whether the machine or the work stopped it" do
        -- The harness's coding agents and declared tools are unavailable:
        -- a step that never started stops the run by its environment, and
        -- the agent run records no learning for it (FRIC-104).
        let run :: Ack -> [PlaybookStep] -> Value
            run answer steps =
              runPureEff
                . unavailableCodingAgent
                . unavailableDeclaredTool
                . interpret (\_ -> \case AwaitAcknowledgement {} -> pure answer; AwaitAcknowledgementWithin {} -> pure answer)
                . interpret (\_ -> \case Recall {} -> pure []; Remember {} -> error "nothing is remembered without learnings")
                $ runPlaybook
                  PlaybookAgent {provider = ClaudeCode, access = EditWorkspace, model = Nothing, effort = Nothing}
                  PinnedPlaybook {bundle = Bundle {main = "m", playbooks = [Playbook {name = "m", steps}]}, file = "bundle.dhall", repository = Nothing, relative = "bundle.dhall"}
                  Null
            stoppedBy output = case output of Object fields -> KeyMap.lookup "stoppedBy" fields; _ -> Nothing
            gate = Approval {id = "gate", prompt = "Continue?"}
            probe = Probe {id = "probe", tool = "git", args = ["status"], deadlineMinutes = 1}
            coder = CodingAgent {id = "fix", prompt = "Fix it", workspace = "", deadlineMinutes = 5, skills = []}
            oversized = CodingAgent {id = "fix", prompt = Text.replicate 70000 "x", workspace = "", deadlineMinutes = 5, skills = []}
        stoppedBy (run (Acknowledged Null) [gate]) @?= Just Null
        stoppedBy (run (Declined "not now") [gate]) @?= Just (String "work")
        stoppedBy (run (Acknowledged Null) [gate, probe]) @?= Just (String "environment")
        stoppedBy (run (Acknowledged Null) [coder]) @?= Just (String "environment")
        stoppedBy (run (Acknowledged Null) [oversized]) @?= Just (String "environment")
        fmap stoppedByEnvironment [run (Declined "no") [gate], run (Acknowledged Null) [probe]] @?= [False, True],
      testCase "a ProbeIn or ToolIn step runs in its rendered workspace, a Probe or Tool in the run's" do
        -- Each item of a multi-repository run probes and checks its own
        -- repository, not the run's workspace.
        let workspaces :: [Value] -> [PlaybookStep] -> [Maybe Text.Text]
            workspaces repos body =
              reverse
                . runPureEff
                . execState []
                . unavailableCodingAgent
                . interpret (\_ -> \case RunToolStep elsewhere _ _ -> modify (elsewhere :) >> pure (ToolCompleted ToolRun {exit = 0, stdout = "", stderr = "", droppedBytes = 0, elapsedMs = 0}))
                . interpret (\_ -> \case AwaitAcknowledgement {} -> pure (Acknowledged Null); AwaitAcknowledgementWithin {} -> pure (Acknowledged Null))
                . interpret (\_ -> \case Recall {} -> pure []; Remember {} -> error "nothing is remembered without learnings")
                $ runPlaybook
                  PlaybookAgent {provider = ClaudeCode, access = EditWorkspace, model = Nothing, effort = Nothing}
                  PinnedPlaybook
                    { bundle =
                        Bundle
                          { main = "m",
                            playbooks =
                              [ Playbook {name = "m", steps = [ForEach {id = "each", items = FromPayload "repos", item = "repo", playbook = "one"}]},
                                Playbook {name = "one", steps = body}
                              ]
                          },
                      file = "bundle.dhall",
                      repository = Nothing,
                      relative = "bundle.dhall"
                    }
                  (Object (KeyMap.singleton "repos" (Array (foldMap pure repos))))
            perRepository =
              [ ProbeIn {id = "start", tool = "git", args = ["rev-parse", "HEAD"], deadlineMinutes = 1, workspace = "{{repo}}"},
                ToolIn {id = "check", tool = "nix", args = ["develop"], deadlineMinutes = 1, workspace = "{{repo}}"},
                Probe {id = "here", tool = "git", args = ["status"], deadlineMinutes = 1}
              ]
        workspaces [String "mori://x/a", String "mori://x/b"] perRepository
          @?= [Just "mori://x/a", Just "mori://x/a", Nothing, Just "mori://x/b", Just "mori://x/b", Nothing]
        validateBundle Bundle {main = "m", playbooks = [Playbook {name = "m", steps = [Probe {id = "p", tool = "git", args = [], deadlineMinutes = 1}, ProbeIn {id = "q", tool = "git", args = [], deadlineMinutes = 1, workspace = "{{steps.p.output}}"}]}]}
          @?= [ObservedWorkspace "m" "q" "steps.p.output"]
    ]
