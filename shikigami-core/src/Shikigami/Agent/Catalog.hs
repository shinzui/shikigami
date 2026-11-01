-- | Boot-time declarations joined to the current lifecycle directory.
module Shikigami.Agent.Catalog
  ( AgentCatalog (..),
    catalogFromReport,
    lookupAgent,
    emptyCatalog,
    AgentLifecycleView (..),
    agentLifecycle,
    runnable,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), loadedAgents)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Prelude

data AgentCatalog = AgentCatalog
  {declarations :: !(Map AgentName AgentDecl), failedManifests :: !Int}

catalogFromReport :: AgentLoadReport -> AgentCatalog
catalogFromReport report =
  AgentCatalog
    (Map.fromList [(decl.name, decl) | decl <- loadedAgents report])
    (length [() | AgentLoadFailed {} <- report.entries])

emptyCatalog :: AgentCatalog
emptyCatalog = AgentCatalog Map.empty 0

lookupAgent :: AgentCatalog -> AgentName -> Maybe AgentDecl
lookupAgent catalog name = Map.lookup name catalog.declarations

data AgentLifecycleView
  = LifecycleActive
  | LifecyclePaused
  | LifecycleDeactivated
  | LifecycleUnknown
  | LifecycleUnverified
  deriving stock (Eq, Show)

agentLifecycle :: Bool -> DirectoryHandle -> AgentDecl -> IO AgentLifecycleView
agentLifecycle configured directory decl = do
  principal <- Directory.lookupPrincipal directory ((.principal) <$> decl.identity) (agentNameText decl.name)
  pure $ case principal of
    Just record -> case record.lifecycle of
      Active -> LifecycleActive
      Paused -> LifecyclePaused
      Deactivated -> LifecycleDeactivated
    Nothing | configured -> LifecycleUnknown
    Nothing -> LifecycleUnverified

runnable :: AgentDecl -> AgentLifecycleView -> Bool
runnable decl lifecycle = agentEnabled decl.enabled && lifecycle `elem` [LifecycleActive, LifecycleUnverified]
