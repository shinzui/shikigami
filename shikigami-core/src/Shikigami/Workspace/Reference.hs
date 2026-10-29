-- | Public provider/resource coordinates shared by snapshots and transfers.
module Shikigami.Workspace.Reference (WorkspaceRef (..)) where

import Shikigami.Prelude

data WorkspaceRef = WorkspaceRef {provider :: !Text, resource :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
