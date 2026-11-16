-- | @shikigami flows@, and the composition the offline flow commands share.
--
-- @validate@, @render-lifecycle@ and @flows@ all answer from the packs this
-- executable was composed with, so a distribution's admin command and the
-- stock one differ only in the list they were given.
module Shikigami.Server.Command.Flows
  ( composeOrDie,
    renderFlowLines,
    runFlows,
  )
where

import Data.Foldable (traverse_)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Decision.Contract (DecisionSlot (..), decisionSlotLabelText)
import Shikigami.Flow (FlowDef (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack
import Shikigami.RuntimePolicy (defaultModelRequired)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Compose the builtin pack with a distribution's packs, quietly. An admin
-- command prints its answer on stdout, so a successful composition says
-- nothing; a refused one names every error and exits non-zero.
composeOrDie :: [FlowPack] -> IO FlowRegistry
composeOrDie packs =
  case composeFlowRegistry (builtinPack : packs) of
    Right registry -> pure registry
    Left errors -> do
      traverse_ (\problem -> hPutStrLn stderr ("shikigami: flow packs refused: " <> Text.unpack (renderFlowRegistryError problem))) (NonEmpty.toList errors)
      exitFailure

-- | One line per composed flow: its pack, its name, whether it needs the
-- default model, and its decision slot labels.
renderFlowLines :: FlowRegistry -> [Text]
renderFlowLines registry = map line entries
  where
    entries = registeredFlows registry
    packWidth = maximum (0 : [Text.length (flowPackNameText entry.pack) | entry <- entries])
    nameWidth = maximum (0 : [Text.length (declarationCoordinateText entry.flow.definition.name) | entry <- entries])
    line entry =
      Text.intercalate
        "  "
        [ Text.justifyLeft packWidth ' ' (flowPackNameText entry.pack),
          Text.justifyLeft nameWidth ' ' (declarationCoordinateText entry.flow.definition.name),
          "default-model=" <> (if defaultModelRequired entry.flow.definition.requiresDefaultModel then "required" else "optional"),
          "slots=" <> slots entry.flow.definition.decisionSlots
        ]
    slots [] = "-"
    slots declared = Text.intercalate "," [decisionSlotLabelText slot.label | slot <- declared]

runFlows :: [FlowPack] -> IO ()
runFlows packs = composeOrDie packs >>= traverse_ TIO.putStrLn . renderFlowLines
