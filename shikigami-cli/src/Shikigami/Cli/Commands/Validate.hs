module Shikigami.Cli.Commands.Validate
  ( runValidate,
  )
where

import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Agent.Skill (validateSkill)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Parse a manifest, pretty-print it, and (for a skill-agent) validate its
-- SKILL.md. Exits 0 on success, non-zero on any load or skill error.
runValidate :: FilePath -> IO ()
runValidate path = do
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("validate: load error in " <> path <> ":\n" <> Text.unpack msg)
      exitFailure
    Right decl -> do
      print decl -- the Show-rendered manifest
      case behavior decl of
        Skill {path = skillDir} -> do
          let skillDir' = Text.unpack skillDir
          skillResult <- validateSkill skillDir'
          case skillResult of
            Left err -> do
              hPutStrLn stderr ("validate: skill error: " <> show err)
              exitFailure
            Right () -> putStrLn ("OK: 1 agent parsed (skill " <> skillDir' <> " valid).")
        _ -> putStrLn "OK: 1 agent parsed."
