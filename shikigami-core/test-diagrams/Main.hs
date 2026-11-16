module Main (main) where

import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Keiki.Render.Validate (MermaidValidationOptions (..), defaultMermaidValidationOptions, validateMermaidAtlas)
import Shikigami.Diagrams (domainAtlas, domainEdgeInspectors)
import System.Environment (getArgs, withArgs)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--write-atlas"] -> do
      Text.writeFile "../docs/architecture/domain-atlas.md" domainAtlas
      Text.writeFile "../docs/architecture/domain-edge-inspectors.md" domainEdgeInspectors
    _ -> withArgs args tests

tests :: IO ()
tests =
  defaultMain $
    testGroup
      "lifecycle diagrams"
      [ testCase "the complete atlas passes readable Mermaid validation" do
          assertEqual "Mermaid findings" [] (validateMermaidAtlas defaultMermaidValidationOptions {maxLabelLength = Nothing, suspiciousChars = ['\"', '{', '}']} domainAtlas),
        testCase "checked-in diagrams match executable transducers" do
          atlas <- Text.readFile "../docs/architecture/domain-atlas.md"
          inspectors <- Text.readFile "../docs/architecture/domain-edge-inspectors.md"
          assertEqual "atlas drift; run just domain-diagrams" domainAtlas atlas
          assertEqual "edge inspector drift; run just domain-diagrams" domainEdgeInspectors inspectors
      ]
