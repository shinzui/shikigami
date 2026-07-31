module Shikigami.Server.Command.Validate
  ( runValidate,
  )
where

import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Agent.Skill (validateSkill)
import Shikigami.Sink.Validate (sinkDeclarationErrors)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Parse a manifest, pretty-print it, check its sinks, and (for a skill-agent)
-- validate its SKILL.md. Exits 0 on success, non-zero on any load, sink, or
-- skill error.
--
-- The sink check is what refuses a declaration whose routing can never be
-- answered — see "Shikigami.Sink.Validate". It runs before the skill check
-- because it needs nothing from the filesystem, so a manifest with both problems
-- reports the cheaper one first.
runValidate :: FilePath -> IO ()
runValidate path = do
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("validate: load error in " <> path <> ":\n" <> Text.unpack msg)
      exitFailure
    Right decl -> do
      print decl -- the Show-rendered manifest
      case sinkDeclarationErrors decl of
        errors@(_ : _) -> do
          traverse_ (\err -> hPutStrLn stderr ("validate: sink error: " <> Text.unpack err)) errors
          exitFailure
        [] -> pure ()
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
