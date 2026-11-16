{-# LANGUAGE RankNTypes #-}

-- | An operator verb a flow pack contributes to the admin command
-- (docs/adr/0129).
--
-- A use case's inspection and governance verbs belong with the use case. A
-- pack lists them as 'AdminVerb' values, and the admin command of an
-- executable composed with the pack mounts each beside the kernel's own
-- verbs; a stock admin command, which composes no pack, does not have them.
--
-- A verb never sees the process configuration. The admin command resolves
-- configuration, then hands the verb an 'AdminContext': the few reads and the
-- one store entry point an operator verb needs. Opening the store verifies the
-- schema first, as every kernel verb does.
module Shikigami.Pack.Admin
  ( AdminVerb (..),
    AdminContext (..),
  )
where

import Data.Text (Text)
import Effectful (Eff)
import Kiroku.Store.Error (StoreError)
import Options.Applicative (ParserInfo)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Principal (AgentPrincipal)
import Shikigami.App (AppEffects)
import Shikigami.Objective.Types (ObjectiveSettings)
import Shikigami.Pack.Setting (PackSettings)
import Shikigami.Repository (RepositoryId)

-- | One top-level verb, e.g. @proposals@, with its own subcommands and help.
-- The name is unique across the kernel's verbs and every composed pack's.
data AdminVerb = AdminVerb
  { name :: !Text,
    parser :: !(ParserInfo (AdminContext -> IO ()))
  }

-- | What the admin command gives a pack's verb.
data AdminContext = AdminContext
  { -- | The validated settings of the composed packs.
    settings :: !PackSettings,
    -- | Objective enablement and the configured local operator, whose
    -- identity a governing verb acts as.
    objectives :: !ObjectiveSettings,
    -- | The repositories of the operator's workspace catalog.
    repositories :: ![RepositoryId],
    -- | The agent declarations of the configured manifests directory.
    declarations :: !(IO [AgentDecl]),
    -- | Whether a principal is active in the directory right now.
    principalActive :: !(AgentPrincipal -> IO Bool),
    -- | Run against the database: resolve its address, verify the schema, open
    -- the store. A missing address or a schema mismatch exits the process, as
    -- for a kernel verb; a store failure is returned.
    runStore :: !(forall a. Eff AppEffects a -> IO (Either StoreError a))
  }
