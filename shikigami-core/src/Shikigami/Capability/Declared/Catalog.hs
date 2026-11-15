-- | The operator's tools file (EP-3 of MasterPlan 22).
--
-- A declared CLI tool needs no entry here: the operator's one-time grant of
-- the declaration is its authority (ADR 0124). The file holds optional
-- ceilings; when one names a declared tool, the declaration must fit under it
-- (the same executable, every pattern inside a ceiling pattern, and an
-- operation class no higher). MCP server bindings join this file in EP-3 M2.
module Shikigami.Capability.Declared.Catalog
  ( CliToolCeiling (..),
    ToolCatalog (..),
    emptyToolCatalog,
    defaultToolCatalogPath,
    loadToolCatalog,
    ToolResolutionError (..),
    renderToolResolutionError,
    checkDeclaredTools,
  )
where

import Control.Exception (SomeException, try)
import Data.List (find, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall)
import Dhall qualified
import GHC.Generics (Generic)
import Shikigami.Capability.Declared
import Shikigami.Capability.Overlay (CapabilityOperationClass)
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory)
import System.FilePath ((</>))

data CliToolCeiling = CliToolCeiling
  { name :: !ToolName,
    executable :: !ExecutableRef,
    allow :: ![ArgumentPattern],
    maximumOperationClass :: !CapabilityOperationClass
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall CliToolCeiling

newtype ToolCatalog = ToolCatalog
  { cli :: [CliToolCeiling]
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall ToolCatalog

emptyToolCatalog :: ToolCatalog
emptyToolCatalog = ToolCatalog {cli = []}

-- | @$XDG_CONFIG_HOME/shikigami/tools.dhall@.
defaultToolCatalogPath :: IO FilePath
defaultToolCatalogPath = (</> "tools.dhall") <$> getXdgDirectory XdgConfig "shikigami"

-- | A missing file is the empty catalog.
loadToolCatalog :: FilePath -> IO (Either Text ToolCatalog)
loadToolCatalog path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right emptyToolCatalog)
    else do
      loaded <- try @SomeException (Dhall.inputFile Dhall.auto path)
      pure case loaded of
        Left problem -> Left ("the tools file " <> Text.pack path <> " does not load: " <> Text.pack (show problem))
        Right catalog -> Right catalog

data ToolResolutionError
  = DuplicateToolDeclaration !ToolName
  | ExecutableNotFound !ToolName !ExecutableRef
  | ExecutableDiffersFromCeiling !ToolName
  | PatternOutsideCeiling !ToolName !ArgumentPattern
  | OperationClassAboveCeiling !ToolName !CapabilityOperationClass !CapabilityOperationClass
  | ToolsUnsupportedForBehavior !Text
  | ToolsUnsupportedForTier !Text
  | ToolCatalogUnavailable !Text
  deriving stock (Eq, Show)

renderToolResolutionError :: ToolResolutionError -> Text
renderToolResolutionError = \case
  DuplicateToolDeclaration tool -> "the tool " <> toolNameText tool <> " is declared twice"
  ExecutableNotFound tool executable -> "the executable " <> executableRefText executable <> " of " <> toolNameText tool <> " is not found"
  ExecutableDiffersFromCeiling tool -> toolNameText tool <> " names another executable than the operator ceiling"
  PatternOutsideCeiling tool pattern' -> toolNameText tool <> " pattern [" <> renderPattern pattern' <> "] is outside the operator ceiling"
  OperationClassAboveCeiling tool declared bound -> toolNameText tool <> " declares " <> Text.pack (show declared) <> " above the ceiling's " <> Text.pack (show bound)
  ToolsUnsupportedForBehavior behavior -> "declared tools are not supported for " <> behavior <> " agents"
  ToolsUnsupportedForTier tier -> "declared tools need trust.tier=local-operator; this run is " <> tier
  ToolCatalogUnavailable detail -> detail

-- | The declaration's tools are distinct and each fits any ceiling of its name.
checkDeclaredTools :: ToolCatalog -> [CliToolDecl] -> Either ToolResolutionError ()
checkDeclaredTools ToolCatalog {cli} tools = do
  let names = (.name) <$> tools
  case [tool | tool <- names, length (filter (== tool) names) > 1] of
    duplicate : _ -> Left (DuplicateToolDeclaration duplicate)
    [] -> pure ()
  mapM_ fits (nub tools)
  where
    fits tool = case find (\bound -> bound.name == tool.name) cli of
      Nothing -> Right ()
      Just bound
        | bound.executable /= tool.executable -> Left (ExecutableDiffersFromCeiling tool.name)
        | tool.operationClass > bound.maximumOperationClass -> Left (OperationClassAboveCeiling tool.name tool.operationClass bound.maximumOperationClass)
        | otherwise -> case [p | p <- foldr (:) [] tool.allow, not (any (patternWithin p) bound.allow)] of
            outside : _ -> Left (PatternOutsideCeiling tool.name outside)
            [] -> Right ()
