module Shikigami.Server.Command.Validate
  ( runValidate,
  )
where

import Control.Monad (when)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Agent.Skill (validateSkill)
import Shikigami.Flow.Pack (FlowPack (..), flowDeclarationErrors)
import Shikigami.Output (DefaultOutputChoice (..), renderOutputLoadError, renderResolvedOutputs, resolveOutputs, validateOutputs)
import Shikigami.Output.Local (localReportAdapter)
import Shikigami.Output.Registration (validationRegistry)
import Shikigami.Router.Declaration (renderRouterDeclarationError, routerDeclarationErrors)
import Shikigami.Server.Command.Flows (composeOrDie)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Parse a manifest, pretty-print it, check its outputs and its behavior,
-- and (for a skill-agent) validate its SKILL.md. Exits 0 on success, non-zero
-- on any load, output, flow, or skill error.
--
-- The output check refuses a kind this executable's packs do not register,
-- naming the kinds they do, and a configuration its kind refuses (a signal
-- whose routing can never be answered, say). It prints where a result goes,
-- including the composition's default for a declaration that lists none. It
-- runs before the skill check because it needs nothing from the filesystem,
-- so a manifest with both problems reports the cheaper one first.
--
-- The flow check refuses a @Behavior.Flow { name }@ this executable was not
-- composed with; a distribution's admin command accepts its packs' flows. It
-- belongs here rather than at first trigger because the alternative is a failed
-- agent run per trigger, forever, for a typo a parse-time check can see.
runValidate :: [FlowPack] -> FilePath -> IO ()
runValidate packs path = do
  flows <- composeOrDie packs
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("validate: load error in " <> path <> ":\n" <> Text.unpack msg)
      exitFailure
    Right decl -> do
      print decl -- the Show-rendered manifest
      when (not (agentEnabled ((.enabled) decl))) $ hPutStrLn stderr "note: agent is disabled (enabled = False)"
      case routerDeclarationErrors decl of
        errors@(_ : _) -> do
          traverse_ (\err -> hPutStrLn stderr ("validate: router error: " <> Text.unpack (renderRouterDeclarationError err))) errors
          exitFailure
        [] -> pure ()
      registry <- either (\problem -> hPutStrLn stderr ("validate: " <> Text.unpack problem) >> exitFailure) pure (validationRegistry [localReportAdapter "/"] (concatMap (.outputs) packs) CompositionPreferred)
      case validateOutputs registry decl.outputs of
        Left errors -> do
          traverse_ (\err -> hPutStrLn stderr ("validate: output error: " <> Text.unpack (renderOutputLoadError err))) errors
          exitFailure
        Right () -> putStrLn ("outputs: " <> Text.unpack (renderResolvedOutputs (resolveOutputs registry decl.outputs)))
      case flowDeclarationErrors flows decl of
        errors@(_ : _) -> do
          traverse_ (\err -> hPutStrLn stderr ("validate: " <> Text.unpack err)) errors
          exitFailure
        [] -> pure ()
      let skillPath = case (.behavior) decl of
            Skill {path = skillDir} -> Just skillDir
            CoordinatingSkill {path = skillDir} -> Just skillDir
            _ -> Nothing
      case skillPath of
        Just skillDir -> do
          let skillDir' = Text.unpack (declarationCoordinateText skillDir)
          skillResult <- validateSkill skillDir'
          case skillResult of
            Left err -> do
              hPutStrLn stderr ("validate: skill error: " <> show err)
              exitFailure
            Right () -> putStrLn ("OK: 1 agent parsed (skill " <> skillDir' <> " valid).")
        _ -> putStrLn "OK: 1 agent parsed."
