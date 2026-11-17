{-# LANGUAGE DataKinds #-}

-- | An authority a pack registers under a name (plan 135, M2).
--
-- The kernel owns the authority port ('Authority') and the setting that
-- selects one (@authorization.actions.mode@). A pack that brings a deciding
-- service registers an 'AuthorityAdapter' under the mode that selects it; the
-- Kikan binding registers @kikan@. The adapter is built once, at start, from
-- the validated settings of the composed packs.
module Shikigami.Authority.Adapter
  ( AuthorityAdapter (..),
    AuthorityContext (..),
  )
where

import Data.Text (Text)
import Shikigami.Activity.Coordinate (ActivityCoordinate)
import Shikigami.Authority (Authority)
import Shikigami.Log (Logger)
import Shikigami.Pack.Setting (PackSettings)

-- | What an adapter is built from.
data AuthorityContext = AuthorityContext
  { logger :: !Logger,
    -- | The validated settings of every composed pack, including the
    -- adapter's own.
    settings :: !PackSettings,
    -- | The deployment's Kawa source (@sinks.kawa.source_segment@). It is
    -- here only until plan 135's M3 moves that setting to the Kikan binding.
    kawaSource :: !(ActivityCoordinate "source")
  }

data AuthorityAdapter = AuthorityAdapter
  { -- | The value of @authorization.actions.mode@ that selects this adapter.
    mode :: !Text,
    -- | Build the authority; a 'Left' refuses to start and names what is
    -- missing or invalid, never a secret.
    build :: !(AuthorityContext -> IO (Either Text Authority))
  }
