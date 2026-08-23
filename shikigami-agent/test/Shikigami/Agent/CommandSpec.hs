-- | Both one-off executables have a working command line.
--
-- These are smoke tests in the literal sense: they prove each binary's parser is
-- reachable, renders @--help@, names itself, and keeps its documented options.
-- That is exactly the class of breakage a package split causes — an executable
-- wired to the wrong parser, or one whose options were dropped in the move — and
-- it is invisible to the type checker because every parser has the same type.
--
-- They mirror "Shikigami.Workers.CommandSpec" deliberately: an operator who
-- learns the diagnostic modes on a worker binary should not find them missing on
-- a one-off one, and the only way to keep that true across two packages is to
-- assert it in both.
--
-- They run the parser purely with @execParserPure@ rather than executing a built
-- binary, so they are fast and can assert on the rendered help text.
module Shikigami.Agent.CommandSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Options.Applicative
import Shikigami.Agent.Command
  ( RoleInfo (..),
    agentRoles,
    agentRunRoleInfo,
    runBehaviorRoleInfo,
  )
import Shikigami.Agent.Command.RunBehavior (profileRequirementRefusal)
import Shikigami.Agent.Decl (AgentDecl (..), ProfileRequirement (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.App.Config (Role (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | The options every configurable executable offers, whatever its role.
configurationFlags :: [String]
configurationFlags =
  [ "--config",
    "--set",
    "--describe-config",
    "--describe-config-json",
    "--explain-config",
    "--explain-config-json",
    "--check-config"
  ]

tests :: TestTree
tests =
  testGroup
    "one-off command lines"
    [ testCase "every one-off executable renders --help" $
        mapM_
          ( \info -> do
              let rendered = helpTextOf info
              assertBool
                (binaryName info <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          agentRoles,
      testCase "the two one-off roles are named exactly once each" $
        fmap binaryName agentRoles
          @?= ["shikigami-run-behavior", "shikigami-agent-run"],
      testCase "each binary is wired to the role whose requirements it must meet" $
        fmap role agentRoles @?= [RunBehaviorRole, AgentRunRole],
      testCase "every one-off executable offers the same configuration and diagnostic options" $
        mapM_ (`assertHasAll` configurationFlags) agentRoles,
      testCase "run-behavior keeps its agent and payload options" $
        assertHasAll runBehaviorRoleInfo ["--agent", "--payload", "--workspace"],
      testCase "agent-run keeps its agent and activity options" $
        assertHasAll agentRunRoleInfo ["--agent", "--from-activity", "--workspace"],
      testCase "run-behavior accepts a declaration with no profile" $
        profileRequirementRefusal (testDecl Nothing) @?= Nothing,
      testCase "run-behavior refuses a profile it cannot resolve before dispatch" $
        case profileRequirementRefusal (testDecl (Just requiredProfile)) of
          Nothing -> assertBool "a required profile must be refused" False
          Just refusal -> do
            assertBool "the refusal names the profile" ("sanctioned-review" `Text.isInfixOf` refusal)
            assertBool "the refusal directs the caller to the resolving command" ("shikigami-agent-run" `Text.isInfixOf` refusal)
    ]

testDecl :: Maybe ProfileRequirement -> AgentDecl
testDecl sanctionedProfile =
  AgentDecl
    { name = "profile-command-test",
      description = "profile command test",
      trigger = Event {eventType = "test"},
      behavior = Agent.Skill {path = "agents/skills/triage-note"},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      routing = Nothing
    }

requiredProfile :: ProfileRequirement
requiredProfile =
  ProfileRequirement
    { profileId = "sanctioned-review",
      version = Just "1"
    }

assertHasAll :: RoleInfo -> [String] -> IO ()
assertHasAll info flags =
  let rendered = helpTextOf info
   in mapM_
        ( \flag ->
            assertBool
              (binaryName info <> ": --help does not mention " <> flag <> ":\n" <> rendered)
              (flag `isInfixOf` rendered)
        )
        flags

helpTextOf :: RoleInfo -> String
helpTextOf info =
  case execParserPure defaultPrefs (parserInfo info) ["--help"] of
    Failure failure -> let (message, _) = renderFailure failure (binaryName info) in message
    _ -> ""
