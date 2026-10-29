module Shikigami.WorkspaceInstructionsSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Shikigami.Execution.Policy
import Shikigami.Execution.Transcript
import Shikigami.Workspace.Instructions
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace instructions"
    [ testCase "nested instructions apply to new descendants and never siblings" $ do
        bundle <- right (mkInstructionBundle 65536 repository base [("AGENTS.md", "root"), ("src/AGENTS.md", "nested"), ("src/deep/AGENTS.md", "deep")])
        fmap (map (.text)) (instructionsForPath bundle "src/deep/new/file.hs") @?= Right ["root", "nested", "deep"]
        fmap (map (.text)) (instructionsForPath bundle "src-other/new.hs") @?= Right ["root"]
        fmap (map (.text)) (instructionsForPath bundle "test/new.hs") @?= Right ["root"],
      testCase "instruction and operation paths reject traversal and Git aliases" $ do
        bundle <- right (mkInstructionBundle 65536 repository base [])
        mapM_ (\path -> assertBool "path refused" (isLeft (instructionsForPath bundle path))) ["/tmp/a", "../a", "a/../../b", "a//b", ".git/config", "a/.Git/objects", "a\\b", "a/./b", "a\0b"]
        mapM_ (\path -> assertBool "instruction name refused" (isLeft (mkInstructionBundle 65536 repository base [(path, "body")]))) ["README.md", "../AGENTS.md", "/AGENTS.md"],
      testCase "complete UTF-8 text and file counts are bounded" $ do
        mkInstructionBundle 3 repository base [("AGENTS.md", "日本")] @?= Left InstructionBudgetExceeded
        assertBool "64 files fit" (not (isLeft (mkInstructionBundle 65536 repository base [(Text.pack (show n) <> "/AGENTS.md", "x") | n <- [1 .. 64 :: Int]])))
        mkInstructionBundle 65536 repository base [(Text.pack (show n) <> "/AGENTS.md", "x") | n <- [1 .. 65 :: Int]] @?= Left InstructionBudgetExceeded
        mkInstructionBundle 65536 repository base [("AGENTS.md", Text.replicate 65537 "x")] @?= Left InstructionBudgetExceeded,
      testCase "bundle identity is deterministic and tampered scope or text cannot decode" $ do
        bundle <- right (mkInstructionBundle 65536 repository base [("src/AGENTS.md", "nested"), ("AGENTS.md", "root")])
        reversed <- right (mkInstructionBundle 65536 repository base [("AGENTS.md", "root"), ("src/AGENTS.md", "nested")])
        bundle @?= reversed
        Aeson.fromJSON (Aeson.toJSON bundle) @?= Aeson.Success bundle
        let tampered = case Aeson.toJSON bundle of
              Aeson.Object fields -> Aeson.Object (KeyMap.insert "digest" (Aeson.String "forged") fields)
              value -> value
        assertBool "digest mismatch refused" (case Aeson.fromJSON @InstructionBundle tampered of Aeson.Error _ -> True; _ -> False)
        case bundleFiles bundle of
          [] -> assertFailure "missing fixture instruction"
          entry : rest -> do
            let replacements = [RepositoryInstruction entry.path "forged-scope" entry.digest entry.text, RepositoryInstruction entry.path entry.scope entry.digest "forged body"]
                changed replacement = case Aeson.toJSON bundle of
                  Aeson.Object fields -> Aeson.Object (KeyMap.insert "files" (Aeson.toJSON (replacement : rest)) fields)
                  value -> value
            mapM_ (\replacement -> assertBool "body or scope mismatch refused" (case Aeson.fromJSON @InstructionBundle (changed replacement) of Aeson.Error _ -> True; _ -> False)) replacements,
      testCase "fixed context preserves every instruction through selection and refuses insufficient budget" $ do
        bundle <- right (mkInstructionBundle 65536 repository base [("AGENTS.md", "PRIVATE_ROOT"), ("src/AGENTS.md", "PRIVATE_NESTED")])
        let prompt = Just ("Operator restrictions" <> instructionPrompt bundle)
            context = ReplayContext 2 prompt [RequestTurn [TextBlock "work"] Nothing, UserTurn [TextBlock (Text.replicate 3000 "old")] Nothing, UserTurn [TextBlock "recent"] Nothing]
            policy = defaultHarnessPolicy & #contextBytes .~ 2048 & #keepRecentMessages .~ 1
        selected <- right (selectContextView policy context)
        selected.context.systemPrompt @?= prompt
        assertBool "history compacted" (not (null selected.omitted))
        assertBool "cannot drop fixed instructions" (isLeft (selectContextView (policy & #contextBytes .~ 1024) (context & #systemPrompt .~ Just (Text.replicate 2000 "x" <> instructionPrompt bundle))))
    ]
  where
    repository = "mori://fixture/repo"
    base = Text.replicate 40 "a"
    right :: (Show e) => Either e a -> IO a
    right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
