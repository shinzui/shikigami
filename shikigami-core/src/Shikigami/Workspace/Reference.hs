{-# LANGUAGE DataKinds #-}

-- | Public provider/resource coordinates shared by snapshots and transfers.
module Shikigami.Workspace.Reference (WorkspaceRef (..)) where

import Shikigami.Prelude
import Shikigami.Workspace.Value

data WorkspaceRef = WorkspaceRef {provider :: !(WorkspaceCoordinate "provider"), resource :: !(WorkspaceCoordinate "resource")}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
